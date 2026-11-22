use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Child, Command};
use std::thread;
use std::time::{Duration, Instant};

const ORIGIN: &str = "https://ductdelta.example";
const DATABASE: &str = "host=missing.railway.internal user=ductdelta_app dbname=ductdelta";

fn server_command(port: u16, database: &str) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_ductdelta"));
    command
        .arg("serve")
        .env_clear()
        .env("DUCTDELTA_RAILWAY", "1")
        .env("PORT", port.to_string())
        .env("DUCTDELTA_ORIGIN", ORIGIN)
        .env("DUCTDELTA_DATABASE_URL", database)
        .env("DUCTDELTA_COMPANY_SETUP_CODE", "f".repeat(64));
    command
}

struct Server(Child);

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn request(port: u16, method: &str, host: &str, path: &str) -> String {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    write!(
        stream,
        "{method} {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
    )
    .unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    assert!(
        response
            .split_once("\r\n\r\n")
            .unwrap()
            .0
            .lines()
            .any(|line| line.eq_ignore_ascii_case("strict-transport-security: max-age=31536000")),
        "HTTPS responses must instruct the browser to keep using HTTPS"
    );
    response.lines().next().unwrap().to_owned()
}

#[test]
fn railway_probes_database_and_keeps_app_requests_same_origin() {
    let socket = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = socket.local_addr().unwrap().port();
    drop(socket);
    let mut server = Server(server_command(port, DATABASE).spawn().unwrap());
    let deadline = Instant::now() + Duration::from_secs(5);
    while TcpStream::connect(("127.0.0.1", port)).is_err() {
        assert!(
            server.0.try_wait().unwrap().is_none(),
            "server exited early"
        );
        assert!(Instant::now() < deadline, "server did not bind PORT");
        thread::sleep(Duration::from_millis(20));
    }

    assert_eq!(
        request(port, "GET", "ductdelta.example", "/api/session"),
        "HTTP/1.1 401 Unauthorized"
    );
    assert_eq!(
        request(port, "GET", "healthcheck.railway.app", "/api/session"),
        "HTTP/1.1 403 Forbidden"
    );
    assert_eq!(
        request(port, "POST", "ductdelta.example", "/api/session"),
        "HTTP/1.1 403 Forbidden"
    );
    assert_eq!(
        request(port, "GET", "healthcheck.railway.app", "/healthz"),
        "HTTP/1.1 503 Service Unavailable"
    );
}

#[test]
fn railway_rejects_public_database_hosts() {
    let output = server_command(8080, "host=database.example user=ductdelta_app")
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("Railway private hostname"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}
