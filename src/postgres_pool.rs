//! Bounded reuse of synchronous PostgreSQL connections for the workspace.

use std::sync::{Arc, Mutex};

use postgres::{Client, Config, Error, NoTls};
use tokio::sync::Semaphore;
use tokio::task;

pub(crate) struct PostgresPool {
    config: Config,
    idle: Mutex<Vec<Client>>,
    permits: Arc<Semaphore>,
}

pub(crate) enum QueryError {
    Busy,
    WorkerFailed,
    Database(Error),
}

impl PostgresPool {
    pub(crate) fn new(config: Config, limit: usize) -> Self {
        Self {
            config,
            idle: Mutex::new(Vec::with_capacity(limit)),
            permits: Arc::new(Semaphore::new(limit)),
        }
    }

    /// Runs a database action once. The action must leave no session state for
    /// the next request, including open transactions or role changes.
    pub(crate) async fn run<T: Send + 'static>(
        self: &Arc<Self>,
        action: impl FnOnce(&mut Client) -> Result<T, Error> + Send + 'static,
    ) -> Result<T, QueryError> {
        let permit = Arc::clone(&self.permits)
            .try_acquire_owned()
            .map_err(|_| QueryError::Busy)?;
        let pool = Arc::clone(self);
        task::spawn_blocking(move || {
            let _permit = permit;
            let mut client = pool.checkout()?;
            let result = action(&mut client);
            if !client.is_closed() {
                pool.idle
                    .lock()
                    .expect("PostgreSQL pool lock poisoned")
                    .push(client);
            }
            result
        })
        .await
        .map_err(|_| QueryError::WorkerFailed)?
        .map_err(QueryError::Database)
    }

    fn checkout(&self) -> Result<Client, Error> {
        loop {
            let idle = self
                .idle
                .lock()
                .expect("PostgreSQL pool lock poisoned")
                .pop();
            let Some(mut client) = idle else {
                return self.config.connect(NoTls);
            };
            // Detect idle disconnects before dispatching the request. A disconnect
            // during the action can leave the write outcome unknown.
            if !client.is_closed() && client.check_connection().is_ok() {
                return Ok(client);
            }
        }
    }
}
