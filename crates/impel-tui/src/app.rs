//! Application state and main render loop

use crossterm::event::{KeyCode, KeyModifiers};
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Frame,
};

use impel_core::coordination::CoordinationState;

use crate::mode::Mode;
use crate::views::{GroundView, LandscapeView, TeamView, View};
use crate::widgets::{AlertPanel, StatusBar, ThreadTree};

/// Main application state
pub struct App {
    /// Current mode (NORMAL, COMMAND, SELECT)
    pub mode: Mode,
    /// Coordination state
    pub state: CoordinationState,
    /// Current view (1=Landscape, 2=Team, 3=Ground)
    pub current_view: u8,
    /// Command input buffer
    pub command_buffer: String,
    /// Status message
    pub status_message: Option<String>,
    /// Whether to show the help overlay
    pub show_help: bool,
    /// Selected thread index
    pub selected_thread: usize,
    /// Whether the system is paused
    pub paused: bool,
}

impl App {
    /// Create a new application instance
    pub fn new() -> Self {
        Self {
            mode: Mode::Normal,
            state: CoordinationState::new(),
            current_view: 1,
            command_buffer: String::new(),
            status_message: None,
            show_help: false,
            selected_thread: 0,
            paused: false,
        }
    }

    /// Render the application
    pub fn render(&self, frame: &mut Frame) {
        let size = frame.area();

        // Main layout: status bar at top, content in middle, command line at bottom
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(1), // Status bar
                Constraint::Min(0),    // Main content
                Constraint::Length(1), // Command line
            ])
            .split(size);

        // Render status bar
        self.render_status_bar(frame, chunks[0]);

        // Render main content with sidebar
        let content_chunks = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([
                Constraint::Length(30), // Thread tree sidebar
                Constraint::Min(0),     // Main view
                Constraint::Length(25), // Alert panel
            ])
            .split(chunks[1]);

        // Thread tree sidebar
        self.render_thread_tree(frame, content_chunks[0]);

        // Main view based on current view number
        match self.current_view {
            1 => self.render_landscape_view(frame, content_chunks[1]),
            2 => self.render_team_view(frame, content_chunks[1]),
            3 => self.render_ground_view(frame, content_chunks[1]),
            _ => self.render_landscape_view(frame, content_chunks[1]),
        }

        // Alert panel
        self.render_alert_panel(frame, content_chunks[2]);

        // Command line / message
        self.render_command_line(frame, chunks[2]);

        // Help overlay if shown
        if self.show_help {
            self.render_help_overlay(frame, size);
        }
    }

    fn render_status_bar(&self, frame: &mut Frame, area: Rect) {
        let status = if self.paused { "PAUSED" } else { "RUNNING" };
        let status_color = if self.paused { Color::Yellow } else { Color::Green };

        let mode_str = match self.mode {
            Mode::Normal => "NORMAL",
            Mode::Command => "COMMAND",
            Mode::Select => "SELECT",
        };

        let view_str = match self.current_view {
            1 => "Landscape",
            2 => "Team",
            3 => "Ground",
            _ => "Unknown",
        };

        let left = Line::from(vec![
            Span::styled(
                format!(" {} ", if self.paused { "⏸" } else { "▶" }),
                Style::default().fg(status_color),
            ),
            Span::raw(format!("{} | ", status)),
            Span::styled(
                format!("{}", mode_str),
                Style::default().add_modifier(Modifier::BOLD),
            ),
        ]);

        let right = Line::from(vec![
            Span::raw(format!("View: {} | ", view_str)),
            Span::raw("Press ? for help "),
        ]);

        let status_bar = Paragraph::new(left)
            .style(Style::default().bg(Color::DarkGray));

        frame.render_widget(status_bar, area);
    }

    fn render_thread_tree(&self, frame: &mut Frame, area: Rect) {
        let threads: Vec<_> = self.state.threads().collect();
        let items: Vec<ListItem> = threads
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let style = if i == self.selected_thread {
                    Style::default().bg(Color::Blue).fg(Color::White)
                } else {
                    Style::default()
                };
                let temp_indicator = if t.temperature.is_hot() {
                    "🔥"
                } else if t.temperature.is_warm() {
                    "🟡"
                } else {
                    "🔵"
                };
                ListItem::new(format!("{} {} {}", temp_indicator, t.state, t.metadata.title))
                    .style(style)
            })
            .collect();

        let list = List::new(items)
            .block(Block::default().title("Threads").borders(Borders::ALL));

        frame.render_widget(list, area);
    }

    fn render_landscape_view(&self, frame: &mut Frame, area: Rect) {
        let block = Block::default()
            .title("Landscape View - Thread Graph")
            .borders(Borders::ALL);

        let content = Paragraph::new("Thread relationship graph visualization\n\nUse j/k to navigate, Enter to select")
            .block(block);

        frame.render_widget(content, area);
    }

    fn render_team_view(&self, frame: &mut Frame, area: Rect) {
        let block = Block::default()
            .title("Team View - Thread Detail")
            .borders(Borders::ALL);

        let threads: Vec<_> = self.state.threads().collect();
        let content = if let Some(thread) = threads.get(self.selected_thread) {
            format!(
                "Thread: {}\nState: {}\nTemperature: {:.2}\nClaimed by: {}\n\n{}",
                thread.metadata.title,
                thread.state,
                thread.temperature.value(),
                thread.claimed_by.as_deref().unwrap_or("(unclaimed)"),
                thread.metadata.description
            )
        } else {
            "No thread selected".to_string()
        };

        let paragraph = Paragraph::new(content).block(block);
        frame.render_widget(paragraph, area);
    }

    fn render_ground_view(&self, frame: &mut Frame, area: Rect) {
        let block = Block::default()
            .title("Ground View - Event Log")
            .borders(Borders::ALL);

        let events: Vec<_> = self.state.all_events();
        let items: Vec<ListItem> = events
            .iter()
            .rev()
            .take(20)
            .map(|e| {
                ListItem::new(format!(
                    "[{}] {}",
                    e.timestamp.format("%H:%M:%S"),
                    e.payload.description()
                ))
            })
            .collect();

        let list = List::new(items).block(block);
        frame.render_widget(list, area);
    }

    fn render_alert_panel(&self, frame: &mut Frame, area: Rect) {
        let block = Block::default()
            .title("Alerts")
            .borders(Borders::ALL);

        let escalations = self.state.open_escalations();
        let items: Vec<ListItem> = escalations
            .iter()
            .take(10)
            .map(|e| {
                let priority_color = match e.priority {
                    impel_core::escalation::EscalationPriority::Critical => Color::Red,
                    impel_core::escalation::EscalationPriority::High => Color::Yellow,
                    impel_core::escalation::EscalationPriority::Medium => Color::White,
                    impel_core::escalation::EscalationPriority::Low => Color::Gray,
                };
                ListItem::new(format!("[{}] {}", e.category, e.title))
                    .style(Style::default().fg(priority_color))
            })
            .collect();

        let list = List::new(items).block(block);
        frame.render_widget(list, area);
    }

    fn render_command_line(&self, frame: &mut Frame, area: Rect) {
        let content = match self.mode {
            Mode::Command => format!(":{}", self.command_buffer),
            _ => self
                .status_message
                .clone()
                .unwrap_or_else(|| "Press : to enter command mode".to_string()),
        };

        let paragraph = Paragraph::new(content);
        frame.render_widget(paragraph, area);
    }

    fn render_help_overlay(&self, frame: &mut Frame, area: Rect) {
        let help_text = r#"
Impel TUI - Help

Navigation:
  j/k     - Move up/down in lists
  h/l     - Switch views left/right
  1/2/3   - Jump to view (Landscape/Team/Ground)
  Enter   - Select/expand item
  Esc     - Cancel/back to normal mode

Commands (: to enter command mode):
  :spawn <title>  - Create new thread
  :kill           - Kill selected thread
  :merge <id>     - Merge into selected thread
  :priority <n>   - Set temperature (0.0-1.0)
  :ack            - Acknowledge selected alert
  :pause          - Pause system
  :resume         - Resume system
  :q              - Quit

Modes:
  NORMAL  - Default navigation mode
  COMMAND - Extended command entry (:)
  SELECT  - Multi-select mode (v)

Press ? to toggle this help
"#;

        let block = Block::default()
            .title("Help")
            .borders(Borders::ALL)
            .style(Style::default().bg(Color::Black));

        let help_area = centered_rect(60, 80, area);
        frame.render_widget(ratatui::widgets::Clear, help_area);
        let paragraph = Paragraph::new(help_text).block(block);
        frame.render_widget(paragraph, help_area);
    }

    /// Handle a key press, returns true if app should quit
    pub fn handle_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> bool {
        match self.mode {
            Mode::Normal => self.handle_normal_key(code, modifiers),
            Mode::Command => self.handle_command_key(code),
            Mode::Select => self.handle_select_key(code),
        }
    }

    fn handle_normal_key(&mut self, code: KeyCode, _modifiers: KeyModifiers) -> bool {
        match code {
            KeyCode::Char('q') => return true,
            KeyCode::Char(':') => {
                self.mode = Mode::Command;
                self.command_buffer.clear();
            }
            KeyCode::Char('v') => {
                self.mode = Mode::Select;
            }
            KeyCode::Char('?') => {
                self.show_help = !self.show_help;
            }
            KeyCode::Char('j') | KeyCode::Down => {
                let thread_count = self.state.threads().count();
                if thread_count > 0 {
                    self.selected_thread = (self.selected_thread + 1) % thread_count;
                }
            }
            KeyCode::Char('k') | KeyCode::Up => {
                let thread_count = self.state.threads().count();
                if thread_count > 0 && self.selected_thread > 0 {
                    self.selected_thread -= 1;
                }
            }
            KeyCode::Char('1') => self.current_view = 1,
            KeyCode::Char('2') => self.current_view = 2,
            KeyCode::Char('3') => self.current_view = 3,
            KeyCode::Char('h') | KeyCode::Left => {
                if self.current_view > 1 {
                    self.current_view -= 1;
                }
            }
            KeyCode::Char('l') | KeyCode::Right => {
                if self.current_view < 3 {
                    self.current_view += 1;
                }
            }
            KeyCode::Char(' ') => {
                self.paused = !self.paused;
                self.status_message = Some(if self.paused {
                    "System paused".to_string()
                } else {
                    "System resumed".to_string()
                });
            }
            _ => {}
        }
        false
    }

    fn handle_command_key(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc => {
                self.mode = Mode::Normal;
                self.command_buffer.clear();
            }
            KeyCode::Enter => {
                self.execute_command();
                self.mode = Mode::Normal;
                self.command_buffer.clear();
            }
            KeyCode::Backspace => {
                self.command_buffer.pop();
            }
            KeyCode::Char(c) => {
                self.command_buffer.push(c);
            }
            _ => {}
        }
        false
    }

    fn handle_select_key(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc => {
                self.mode = Mode::Normal;
            }
            _ => {}
        }
        false
    }

    fn execute_command(&mut self) {
        let parts: Vec<&str> = self.command_buffer.split_whitespace().collect();
        if parts.is_empty() {
            return;
        }

        match parts[0] {
            "q" | "quit" => {
                // Will be handled by returning true from handle_key
            }
            "spawn" => {
                let title = parts[1..].join(" ");
                if title.is_empty() {
                    self.status_message = Some("Usage: :spawn <title>".to_string());
                } else {
                    use impel_core::coordination::Command;
                    let _ = Command::CreateThread {
                        title,
                        description: String::new(),
                        parent_id: None,
                        priority: None,
                    }
                    .execute(&mut self.state);
                    self.status_message = Some("Thread created".to_string());
                }
            }
            "pause" => {
                self.paused = true;
                self.status_message = Some("System paused".to_string());
            }
            "resume" => {
                self.paused = false;
                self.status_message = Some("System resumed".to_string());
            }
            "priority" => {
                if let Some(temp_str) = parts.get(1) {
                    if let Ok(temp) = temp_str.parse::<f64>() {
                        self.status_message = Some(format!("Temperature set to {:.2}", temp));
                    } else {
                        self.status_message = Some("Invalid temperature value".to_string());
                    }
                } else {
                    self.status_message = Some("Usage: :priority <0.0-1.0>".to_string());
                }
            }
            _ => {
                self.status_message = Some(format!("Unknown command: {}", parts[0]));
            }
        }
    }
}

impl Default for App {
    fn default() -> Self {
        Self::new()
    }
}

/// Helper function to create a centered rect
fn centered_rect(percent_x: u16, percent_y: u16, r: Rect) -> Rect {
    let popup_layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(r);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(popup_layout[1])[1]
}
