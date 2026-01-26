//! Level 3: Thread View
//!
//! Thread detail showing:
//! - Thread metadata and state
//! - Temperature breakdown
//! - Dependencies
//! - Recent events
//! - Artifacts

use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Frame,
};

use impel_core::thread::{Thread, ThreadState};
use impel_core::event::Event;

/// Thread view state
pub struct ThreadView {
    /// Selected event index
    pub selected_event: usize,
    /// Scroll offset for events
    pub event_scroll: usize,
}

impl ThreadView {
    pub fn new() -> Self {
        Self {
            selected_event: 0,
            event_scroll: 0,
        }
    }

    /// Render the thread view
    pub fn render(
        &self,
        frame: &mut Frame,
        area: Rect,
        thread: Option<&Thread>,
        events: &[Event],
    ) {
        let Some(thread) = thread else {
            let block = Block::default()
                .title("No Thread Selected")
                .borders(Borders::ALL);
            let paragraph = Paragraph::new("Press 2 to go to Project view and select a thread")
                .block(block);
            frame.render_widget(paragraph, area);
            return;
        };

        // Split into header, main content
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(7),  // Header with thread info
                Constraint::Min(0),     // Events and details
            ])
            .split(area);

        // Header
        self.render_header(frame, chunks[0], thread);

        // Main content: events and temperature
        let main_chunks = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([
                Constraint::Percentage(65),
                Constraint::Percentage(35),
            ])
            .split(chunks[1]);

        self.render_events(frame, main_chunks[0], events);
        self.render_details(frame, main_chunks[1], thread);
    }

    fn render_header(&self, frame: &mut Frame, area: Rect, thread: &Thread) {
        let state_style = match thread.state {
            ThreadState::Embryo => Style::default().fg(Color::Gray),
            ThreadState::Active => Style::default().fg(Color::Green),
            ThreadState::Blocked => Style::default().fg(Color::Yellow),
            ThreadState::Review => Style::default().fg(Color::Magenta),
            ThreadState::Complete => Style::default().fg(Color::Blue),
            ThreadState::Killed => Style::default().fg(Color::Red),
        };

        let temp_style = if thread.temperature.is_hot() {
            Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)
        } else if thread.temperature.is_warm() {
            Style::default().fg(Color::Yellow)
        } else {
            Style::default().fg(Color::Cyan)
        };

        let lines = vec![
            Line::from(vec![
                Span::styled(&thread.metadata.title, Style::default().add_modifier(Modifier::BOLD)),
            ]),
            Line::from(vec![
                Span::raw("State: "),
                Span::styled(format!("{}", thread.state), state_style),
                Span::raw(" | Temperature: "),
                Span::styled(format!("{:.2}", thread.temperature.value()), temp_style),
                Span::raw(format!(" (base: {:.2})", thread.temperature.base_priority())),
            ]),
            Line::from(vec![
                Span::raw("ID: "),
                Span::styled(format!("{}", thread.id), Style::default().fg(Color::DarkGray)),
            ]),
            Line::from(vec![
                Span::raw("Claimed by: "),
                Span::styled(
                    thread.claimed_by.as_deref().unwrap_or("(unclaimed)"),
                    Style::default().fg(Color::Cyan),
                ),
            ]),
            Line::from(vec![
                Span::raw(&thread.metadata.description),
            ]),
        ];

        let block = Block::default()
            .title("Thread Details")
            .borders(Borders::ALL);

        let paragraph = Paragraph::new(lines).block(block);
        frame.render_widget(paragraph, area);
    }

    fn render_events(&self, frame: &mut Frame, area: Rect, events: &[Event]) {
        let items: Vec<ListItem> = events
            .iter()
            .rev()
            .enumerate()
            .map(|(i, event)| {
                let style = if i == self.selected_event {
                    Style::default().bg(Color::DarkGray)
                } else {
                    Style::default()
                };

                let timestamp = event.timestamp.format("%Y-%m-%d %H:%M:%S");
                let description = event.payload.description();

                ListItem::new(Line::from(vec![
                    Span::styled(
                        format!("[{}] ", timestamp),
                        Style::default().fg(Color::DarkGray),
                    ),
                    Span::styled(description, style),
                ]))
            })
            .collect();

        let list = List::new(items)
            .block(
                Block::default()
                    .title(format!("Events ({})", events.len()))
                    .borders(Borders::ALL),
            );

        frame.render_widget(list, area);
    }

    fn render_details(&self, frame: &mut Frame, area: Rect, thread: &Thread) {
        // Split into temperature breakdown and dependencies
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(10),
                Constraint::Min(0),
            ])
            .split(area);

        // Temperature breakdown
        self.render_temperature(frame, chunks[0], thread);

        // Dependencies
        self.render_dependencies(frame, chunks[1], thread);
    }

    fn render_temperature(&self, frame: &mut Frame, area: Rect, thread: &Thread) {
        let temp = &thread.temperature;

        let lines = vec![
            Line::from(format!("Current: {:.3}", temp.value())),
            Line::from(format!("Base Priority: {:.3}", temp.base_priority())),
            Line::from(""),
            Line::from("Components:"),
            Line::from(format!("  Base:    {:.3}", temp.base_priority())),
            Line::from(format!("  Last update: {}", temp.time_since_update().num_minutes())),
            Line::from(format!("    minutes ago")),
        ];

        let block = Block::default()
            .title("Temperature")
            .borders(Borders::ALL);

        let paragraph = Paragraph::new(lines).block(block);
        frame.render_widget(paragraph, area);
    }

    fn render_dependencies(&self, frame: &mut Frame, area: Rect, thread: &Thread) {
        let mut lines = Vec::new();

        // Use related_ids from metadata for dependencies
        if thread.metadata.related_ids.is_empty() && thread.metadata.parent_id.is_none() {
            lines.push(Line::from("No dependencies or relations"));
        } else {
            if let Some(parent_id) = &thread.metadata.parent_id {
                lines.push(Line::from(Span::styled(
                    "Parent thread:",
                    Style::default().fg(Color::Yellow),
                )));
                lines.push(Line::from(format!("  - {}", parent_id)));
            }

            if !thread.metadata.related_ids.is_empty() {
                lines.push(Line::from(Span::styled(
                    "Related threads:",
                    Style::default().fg(Color::Cyan),
                )));
                for rel_id in &thread.metadata.related_ids {
                    lines.push(Line::from(format!("  - {}", rel_id)));
                }
            }
        }

        // Show tags if any
        if !thread.metadata.tags.is_empty() {
            lines.push(Line::from(""));
            lines.push(Line::from("Tags:"));
            lines.push(Line::from(format!("  {}", thread.metadata.tags.join(", "))));
        }

        let block = Block::default()
            .title("Dependencies")
            .borders(Borders::ALL);

        let paragraph = Paragraph::new(lines).block(block);
        frame.render_widget(paragraph, area);
    }

    /// Navigate to next event
    pub fn next_event(&mut self, event_count: usize) {
        if event_count > 0 {
            self.selected_event = (self.selected_event + 1) % event_count;
        }
    }

    /// Navigate to previous event
    pub fn prev_event(&mut self, event_count: usize) {
        if event_count > 0 {
            if self.selected_event > 0 {
                self.selected_event -= 1;
            } else {
                self.selected_event = event_count - 1;
            }
        }
    }
}

impl Default for ThreadView {
    fn default() -> Self {
        Self::new()
    }
}
