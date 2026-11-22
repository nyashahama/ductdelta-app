mod account_sessions;
mod cases;
mod company_access_history;
mod company_setup;
mod company_team;
mod evidence;
mod frontend;
mod invitation_mailer;
mod observation;
mod overview;
mod postgres_pool;
mod request_trace;
mod workspace;

use std::io::Write;
use std::process::ExitCode;
use std::{env, io};

use postgres::config::Host;
use postgres::{Client, Config, NoTls};
use uuid::Uuid;

use crate::observation::{Draft, Observation, ObservationId, OperationId, ProjectId};

const USAGE: &str = "Usage:
  ductdelta capture PROJECT_UUID OPERATION_UUID OBSERVED_AT [LOCATION] < note.txt
  ductdelta list PROJECT_UUID [BEFORE_OBSERVATION_UUID]
  ductdelta show PROJECT_UUID OBSERVATION_UUID
  ductdelta serve
  ductdelta issue-key ACTOR_UUID DISPLAY_NAME
  ductdelta appoint-first-admin COMPANY_UUID ACTOR_UUID

Use an RFC 3339 observation time with an offset, or - if the time is unknown.
Set DUCTDELTA_DATABASE_URL to a PostgreSQL connection on a local Unix socket.";

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            let _ = writeln!(io::stderr().lock(), "{message}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), &'static str> {
    let arguments: Vec<String> = env::args_os()
        .skip(1)
        .map(|argument| {
            argument
                .into_string()
                .map_err(|_| "Arguments must be UTF-8.")
        })
        .collect::<Result<_, _>>()?;
    let mut output = io::stdout().lock();
    let result = match arguments.as_slice() {
        [] => writeln!(output, "{USAGE}"),
        [help] if help == "--help" || help == "-h" => writeln!(output, "{USAGE}"),
        [command] if command == "serve" => return workspace::serve(),
        [command, actor, name] if command == "issue-key" => {
            let actor = Uuid::parse_str(actor).map_err(|_| "Invalid actor UUID.")?;
            let key = workspace::issue_key(&mut connect()?, actor, name)?;
            writeln!(output, "{key}")
        }
        [command, company, actor] if command == "appoint-first-admin" => {
            let company = Uuid::parse_str(company).map_err(|_| "Invalid company UUID.")?;
            let actor = Uuid::parse_str(actor).map_err(|_| "Invalid actor UUID.")?;
            company_setup::appoint_first_admin(&mut connect()?, company, actor)?;
            writeln!(output, "Company administrator appointed.")
        }
        [command, project, operation, observed_at, location @ ..]
            if command == "capture" && location.len() <= 1 =>
        {
            let project = ProjectId(Uuid::parse_str(project).map_err(|_| "Invalid project UUID.")?);
            let operation =
                OperationId(Uuid::parse_str(operation).map_err(|_| "Invalid operation UUID.")?);
            let draft = Draft::try_new(
                project,
                operation,
                observed_at,
                location.first().map(String::as_str),
                &mut io::stdin().lock(),
            )?;
            let saved = draft.save(&mut connect()?)?;
            writeln!(output, "{}", saved.0)
        }
        [command, project, id] if command == "show" => {
            let project = ProjectId(Uuid::parse_str(project).map_err(|_| "Invalid project UUID.")?);
            let id = ObservationId(Uuid::parse_str(id).map_err(|_| "Invalid observation UUID.")?);
            let observation = Observation::find(&mut connect()?, project, id)?
                .ok_or("Observation unavailable in this project.")?;
            observation.write(&mut output)
        }
        [command, project, before @ ..] if command == "list" && before.len() <= 1 => {
            let project = ProjectId(Uuid::parse_str(project).map_err(|_| "Invalid project UUID.")?);
            let before = before
                .first()
                .map(|value| Uuid::parse_str(value).map(ObservationId))
                .transpose()
                .map_err(|_| "Invalid page reference UUID.")?;
            return observation::write_project_list(&mut connect()?, project, before, &mut output);
        }
        _ => return Err(USAGE),
    };
    result.map_err(|_| "Could not write command output.")
}

fn connect() -> Result<Client, &'static str> {
    database_config(DatabaseTransport::LocalSocket)?
        .connect(NoTls)
        .map_err(|_| "Could not connect to PostgreSQL using the configured Unix socket.")
}

#[derive(Clone, Copy)]
enum DatabaseTransport {
    LocalSocket,
    RailwayPrivate,
}

fn database_config(transport: DatabaseTransport) -> Result<Config, &'static str> {
    let connection = env::var("DUCTDELTA_DATABASE_URL")
        .map_err(|_| "Set DUCTDELTA_DATABASE_URL to the PostgreSQL connection settings.")?;
    let config: Config = connection
        .parse()
        .map_err(|_| "Invalid PostgreSQL connection settings.")?;
    let hosts = config.get_hosts();
    let has_explicit_addresses = !config.get_hostaddrs().is_empty();
    match transport {
        DatabaseTransport::LocalSocket
            if has_explicit_addresses || !matches!(hosts, [Host::Unix(_)]) =>
        {
            Err("The command line requires a single local PostgreSQL Unix socket.")
        }
        DatabaseTransport::RailwayPrivate
            if has_explicit_addresses
                || !matches!(hosts, [Host::Tcp(host)] if host
                    .strip_suffix(".railway.internal")
                    .is_some_and(|service| !service.is_empty())) =>
        {
            Err("Use a single Railway private hostname for PostgreSQL.")
        }
        _ => Ok(config),
    }
}
