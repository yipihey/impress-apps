//! Level 4: Event View
//!
//! Atomic event detail showing:
//! - Full event information
//! - Actor details
//! - Payload content
//! - Related events (causation chain)

use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Wrap},
    Frame,
};

use impel_core::event::{Event, EventPayload};

/// Event view state
pub struct EventView {
    /// Scroll offset for content
    pub scroll: usize,
}

impl EventView {
    pub fn new() -> Self {
        Self { scroll: 0 }
    }

    /// Render the event view
    pub fn render(
        &self,
        frame: &mut Frame,
        area: Rect,
        event: Option<Event>,
        related_events: &[Event],
    ) {
        let Some(event) = event.as_ref() else {
            let block = Block::default()
                .title("No Event Selected")
                .borders(Borders::ALL);
            let paragraph = Paragraph::new("Press 3 to go to Thread view and select an event")
                .block(block);
            frame.render_widget(paragraph, area);
            return;
        };

        // Split into header, content, and related events
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(8),   // Header
                Constraint::Min(0),      // Content
                Constraint::Length(10),  // Related events
            ])
            .split(area);

        // Header
        self.render_header(frame, chunks[0], event);

        // Content
        self.render_content(frame, chunks[1], event);

        // Related events
        self.render_related(frame, chunks[2], related_events);
    }

    fn render_header(&self, frame: &mut Frame, area: Rect, event: &Event) {
        let lines = vec![
            Line::from(vec![
                Span::styled("Event ID: ", Style::default().add_modifier(Modifier::BOLD)),
                Span::styled(
                    format!("{}", event.id),
                    Style::default().fg(Color::Cyan),
                ),
            ]),
            Line::from(vec![
                Span::raw("Sequence: "),
                Span::styled(
                    format!("{}", event.sequence),
                    Style::default().fg(Color::Yellow),
                ),
            ]),
            Line::from(vec![
                Span::raw("Timestamp: "),
                Span::raw(event.timestamp.format("%Y-%m-%d %H:%M:%S%.3f UTC").to_string()),
            ]),
            Line::from(vec![
                Span::raw("Entity: "),
                Span::styled(&event.entity_id, Style::default().fg(Color::Green)),
                Span::raw(format!(" ({})", event.entity_type)),
            ]),
            Line::from(vec![
                Span::raw("Actor: "),
                Span::styled(
                    event.actor_id.as_deref().unwrap_or("(system)"),
                    Style::default().fg(Color::Magenta),
                ),
            ]),
        ];

        let block = Block::default()
            .title("Event Information")
            .borders(Borders::ALL);

        let paragraph = Paragraph::new(lines).block(block);
        frame.render_widget(paragraph, area);
    }

    fn render_content(&self, frame: &mut Frame, area: Rect, event: &Event) {
        let content = self.format_payload(&event.payload);

        let block = Block::default()
            .title("Payload")
            .borders(Borders::ALL);

        let paragraph = Paragraph::new(content)
            .block(block)
            .wrap(Wrap { trim: false });

        frame.render_widget(paragraph, area);
    }

    fn format_payload(&self, payload: &EventPayload) -> Vec<Line<'static>> {
        let mut lines = Vec::new();

        // Add type indicator
        lines.push(Line::from(vec![
            Span::styled("Type: ", Style::default().add_modifier(Modifier::BOLD)),
            Span::styled(
                payload.description(),
                Style::default().fg(Color::Cyan),
            ),
        ]));
        lines.push(Line::from(""));

        // Add payload-specific details
        match payload {
            EventPayload::ThreadCreated { title, description, parent_id } => {
                lines.push(Line::from(format!("Title: {}", title)));
                lines.push(Line::from(format!("Description: {}", description)));
                if let Some(parent) = parent_id {
                    lines.push(Line::from(format!("Parent: {}", parent)));
                }
            }
            EventPayload::ThreadStateChanged { from, to, reason } => {
                lines.push(Line::from(format!("From: {}", from)));
                lines.push(Line::from(format!("To: {}", to)));
                if let Some(r) = reason {
                    lines.push(Line::from(format!("Reason: {}", r)));
                }
            }
            EventPayload::ThreadClaimed { agent_id } => {
                lines.push(Line::from(format!("Agent: {}", agent_id)));
            }
            EventPayload::ThreadReleased { agent_id } => {
                lines.push(Line::from(format!("Agent: {}", agent_id)));
            }
            EventPayload::ThreadTemperatureChanged { old_value, new_value, reason } => {
                lines.push(Line::from(format!("Old: {:.3}", old_value)));
                lines.push(Line::from(format!("New: {:.3}", new_value)));
                lines.push(Line::from(format!("Reason: {}", reason)));
            }
            EventPayload::EscalationCreated { category, title, thread_id } => {
                lines.push(Line::from(format!("Category: {:?}", category)));
                lines.push(Line::from(format!("Title: {}", title)));
                if let Some(tid) = thread_id {
                    lines.push(Line::from(format!("Thread: {}", tid)));
                }
            }
            EventPayload::EscalationResolved { resolver_id, resolution } => {
                lines.push(Line::from(format!("Resolver: {}", resolver_id)));
                lines.push(Line::from(format!("Resolution: {}", resolution)));
            }
            EventPayload::AgentRegistered { agent_type, capabilities } => {
                lines.push(Line::from(format!("Type: {}", agent_type)));
                lines.push(Line::from("Capabilities:"));
                for cap in capabilities {
                    lines.push(Line::from(format!("  - {}", cap)));
                }
            }
            _ => {
                // Generic fallback
                lines.push(Line::from("(Full payload details not rendered)"));
            }
        }

        lines
    }

    fn render_related(&self, frame: &mut Frame, area: Rect, related: &[Event]) {
        let mut lines = Vec::new();

        if related.is_empty() {
            lines.push(Line::from("No related events in causation chain"));
        } else {
            lines.push(Line::from(format!(
                "Causation chain ({} events):",
                related.len()
            )));
            for event in related.iter().take(5) {
                lines.push(Line::from(vec![
                    Span::styled(
                        format!("[{}] ", event.timestamp.format("%H:%M:%S")),
                        Style::default().fg(Color::DarkGray),
                    ),
                    Span::raw(event.payload.description()),
                ]));
            }
            if related.len() > 5 {
                lines.push(Line::from(format!("  ... and {} more", related.len() - 5)));
            }
        }

        let block = Block::default()
            .title("Related Events")
            .borders(Borders::ALL);

        let paragraph = Paragraph::new(lines).block(block);
        frame.render_widget(paragraph, area);
    }

    /// Scroll up
    pub fn scroll_up(&mut self) {
        self.scroll = self.scroll.saturating_sub(1);
    }

    /// Scroll down
    pub fn scroll_down(&mut self) {
        self.scroll += 1;
    }
}

impl Default for EventView {
    fn default() -> Self {
        Self::new()
    }
}
