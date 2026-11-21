//! Project-scoped capture and retrieval through PostgreSQL's guarded commands.

use std::borrow::Cow;
use std::io;
use std::io::{Read, Write};

use postgres::error::SqlState;
use postgres::{Client, Error};
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};
use uuid::Uuid;

const NOTE_CHARACTERS: usize = 4000;
const LOCATION_CHARACTERS: usize = 120;

pub(crate) struct ProjectId(pub(crate) Uuid);
pub(crate) struct OperationId(pub(crate) Uuid);
pub(crate) struct ObservationId(pub(crate) Uuid);

pub(crate) struct Draft<'input> {
    project: ProjectId,
    operation: OperationId,
    observed_at: Option<OffsetDateTime>,
    location: Option<&'input str>,
    note: String,
}

impl<'input> Draft<'input> {
    pub(crate) fn try_new(
        project: ProjectId,
        operation: OperationId,
        observed_at: &str,
        location: Option<&'input str>,
        input: &mut impl Read,
    ) -> Result<Self, &'static str> {
        let observed_at = match observed_at {
            "-" => None,
            value => Some(parse_observed_time(value)?),
        };
        if let Some(location) = location
            && !valid_text(location, LOCATION_CHARACTERS)
        {
            return Err("Use a nonblank location of at most 120 characters or omit it.");
        }
        // UTF-8 uses at most four bytes per character. Bound reads before decoding.
        let byte_limit = NOTE_CHARACTERS * 4;
        let mut bytes = Vec::new();
        input
            .take((byte_limit + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| "Could not read the observation from standard input.")?;
        if bytes.len() > byte_limit {
            return Err("Use a nonblank observation of at most 4000 characters.");
        }
        let note = String::from_utf8(bytes).map_err(|_| "The observation must be UTF-8 text.")?;
        if !valid_text(&note, NOTE_CHARACTERS) {
            return Err("Use a nonblank observation of at most 4000 characters.");
        }
        Ok(Self {
            project,
            operation,
            observed_at,
            location,
            note,
        })
    }

    pub(crate) fn save(&self, database: &mut Client) -> Result<ObservationId, &'static str> {
        let row = database
            .query_one(
                "SELECT ductdelta.capture_observation($1, $2, $3, $4, $5)",
                &[
                    &self.project.0,
                    &self.operation.0,
                    &self.observed_at,
                    &self.location,
                    &self.note,
                ],
            )
            .map_err(capture_error)?;
        row.try_get(0).map(ObservationId).map_err(|_| READ_ERROR)
    }
}

pub(crate) struct Observation {
    id: ObservationId,
    project: ProjectId,
    actor: Uuid,
    observed_at: Option<OffsetDateTime>,
    recorded_at: OffsetDateTime,
    location: Option<String>,
    note: String,
}

const READ_ERROR: &str = "Could not read the observation from PostgreSQL.";

impl Observation {
    pub(crate) fn find(
        database: &mut Client,
        project: ProjectId,
        id: ObservationId,
    ) -> Result<Option<Self>, &'static str> {
        let row = database
            .query_opt(
                "SELECT id, project_id, actor_id, observed_at, recorded_at, location, note
                 FROM ductdelta.read_observation($1, $2)",
                &[&project.0, &id.0],
            )
            .map_err(|_| READ_ERROR)?;
        row.map(|row| {
            Ok(Observation {
                id: ObservationId(row.try_get("id")?),
                project: ProjectId(row.try_get("project_id")?),
                actor: row.try_get("actor_id")?,
                observed_at: row.try_get("observed_at")?,
                recorded_at: row.try_get("recorded_at")?,
                location: row.try_get("location")?,
                note: row.try_get("note")?,
            })
        })
        .transpose()
        .map_err(|_: Error| READ_ERROR)
    }

    pub(crate) fn write(&self, output: &mut impl Write) -> io::Result<()> {
        writeln!(output, "Observation: {}", self.id.0)?;
        writeln!(output, "Project: {}", self.project.0)?;
        writeln!(output, "Actor: {}", self.actor)?;
        match self.observed_at {
            Some(at) => writeln!(output, "Observed at: {}", format_time(at)?),
            None => writeln!(output, "Observed at: unknown"),
        }?;
        writeln!(output, "Recorded at: {}", format_time(self.recorded_at)?)?;
        let location = display_text(self.location.as_deref().unwrap_or("unspecified"), &[]);
        let note = display_text(&self.note, &['\n', '\t']);
        writeln!(output, "Location: {location}\n\n{note}")
    }
}

fn valid_text(value: &str, max_characters: usize) -> bool {
    !value.trim().is_empty() && !value.contains('\0') && value.chars().count() <= max_characters
}

fn display_text<'text>(value: &'text str, allowed_controls: &[char]) -> Cow<'text, str> {
    let needs_escape =
        |character: char| character.is_control() && !allowed_controls.contains(&character);
    let Some((offset, _)) = value
        .char_indices()
        .find(|&(_, character)| needs_escape(character))
    else {
        return Cow::Borrowed(value);
    };
    let mut display = value[..offset].to_owned();
    for character in value[offset..].chars() {
        if needs_escape(character) {
            display.extend(character.escape_default());
        } else {
            display.push(character);
        }
    }
    Cow::Owned(display)
}

fn parse_observed_time(value: &str) -> Result<OffsetDateTime, &'static str> {
    if let Some((_, fraction)) = value.split_once('.')
        && fraction.bytes().take_while(u8::is_ascii_digit).count() > 6
    {
        return Err("Use microsecond precision or less for the observation time.");
    }
    OffsetDateTime::parse(value, &Rfc3339)
        .ok()
        .and_then(|time| time.checked_to_offset(UtcOffset::UTC))
        .filter(|time| time.year() > 0)
        .ok_or("Use an RFC 3339 observation time with an offset, or - if unknown.")
}

fn format_time(value: OffsetDateTime) -> io::Result<String> {
    value.format(&Rfc3339).map_err(io::Error::other)
}

fn capture_error(error: Error) -> &'static str {
    match error.code() {
        Some(code) if code == &SqlState::INSUFFICIENT_PRIVILEGE => {
            "No capture access to this project."
        }
        Some(code) if code.code() == "DD001" => {
            "This operation ID already records a different observation."
        }
        _ => "Could not save the observation in PostgreSQL.",
    }
}
