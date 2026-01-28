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
use impel_core::event::Event;
use impel_core::program::{Program, ProgramId, ProgramRegistry};
use impel_core::project::{Project, ProjectId};
use impel_core::thread::ThreadId;

use crate::mode::Mode;
use crate::views::{
    EventView, GroundView, LandscapeView, ProgramView, ProjectView, TeamView, ThreadView, View,
    ZoomLevel,
};
use crate::widgets::{AlertPanel, StatusBar, ThreadTree};

/// Main application state
pub struct App {
    /// Current mode (NORMAL, COMMAND, SELECT)
    pub mode: Mode,
    /// Coordination state
    pub state: CoordinationState,
    /// Program and project registry
    pub registry: ProgramRegistry,
    /// Current zoom level (1-4)
    pub zoom_level: ZoomLevel,
    /// Command input buffer
    pub command_buffer: String,
    /// Status message
    pub status_message: Option<String>,
    /// Whether to show the help overlay
    pub show_help: bool,
    /// Currently selected program ID
    pub selected_program: Option<ProgramId>,
    /// Currently selected project ID
    pub selected_project: Option<ProjectId>,
    /// Selected thread index
    pub selected_thread: usize,
    /// Selected event index
    pub selected_event: usize,
    /// Whether the system is paused
    pub paused: bool,
    /// View state for each level
    pub program_view: ProgramView,
    pub project_view: ProjectView,
    pub thread_view: ThreadView,
    pub event_view: EventView,
}

impl App {
    /// Create a new application instance
    pub fn new() -> Self {
        let mut registry = ProgramRegistry::new();

        // Create a default program and project for demo
        let mut program = Program::new(
            "Research 2024".to_string(),
            "Annual research program".to_string(),
        );
        let program_id = program.id;

        let mut project = Project::new(
            "CMB Anomalies".to_string(),
            "Investigation of cosmic microwave background anomalies".to_string(),
        );
        project.goals = vec![
            "Identify statistically significant anomalies".to_string(),
            "Develop theoretical explanations".to_string(),
            "Prepare publication-ready analysis".to_string(),
        ];
        let project_id = project.id;

        program.add_project(project_id);
        registry.add_program(program);
        registry.add_project(project);

        Self {
            mode: Mode::Normal,
            state: CoordinationState::new(),
            registry,
            zoom_level: ZoomLevel::Program,
            command_buffer: String::new(),
            status_message: None,
            show_help: false,
            selected_program: Some(program_id),
            selected_project: Some(project_id),
            selected_thread: 0,
            selected_event: 0,
            paused: false,
            program_view: ProgramView::new(),
            project_view: ProjectView::new(),
            thread_view: ThreadView::new(),
            event_view: EventView::new(),
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

        // Main view based on zoom level
        self.render_main_view(frame, content_chunks[1]);

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
        let status_color = if self.paused {
            Color::Yellow
        } else {
            Color::Green
        };

        let mode_str = self.mode.short_code();
        let mode_color = match self.mode {
            Mode::Normal => Color::Blue,
            Mode::Insert => Color::Green,
            Mode::Command => Color::Magenta,
            Mode::Select => Color::Yellow,
        };

        let left = Line::from(vec![
            Span::styled(
                format!(" {} ", if self.paused { "||" } else { ">>" }),
                Style::default().fg(status_color),
            ),
            Span::raw(format!("{} | ", status)),
            Span::styled(
                format!("[{}]", mode_str),
                Style::default().fg(mode_color).add_modifier(Modifier::BOLD),
            ),
        ]);

        let right = Line::from(vec![
            Span::styled(
                format!("L{}: {} ", self.zoom_level as u8, self.zoom_level.name()),
                Style::default().fg(Color::Cyan),
            ),
            Span::raw("| "),
            Span::raw("Press ? for help "),
        ]);

        // Combine left and right - use left for now
        let status_bar = Paragraph::new(left).style(Style::default().bg(Color::DarkGray));

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
                    "H"
                } else if t.temperature.is_warm() {
                    "W"
                } else {
                    "C"
                };
                ListItem::new(format!(
                    "[{}] {} {}",
                    temp_indicator, t.state, t.metadata.title
                ))
                .style(style)
            })
            .collect();

        let list = List::new(items).block(Block::default().title("Threads").borders(Borders::ALL));

        frame.render_widget(list, area);
    }

    fn render_main_view(&self, frame: &mut Frame, area: Rect) {
        match self.zoom_level {
            ZoomLevel::Program => self.render_program_view(frame, area),
            ZoomLevel::Project => self.render_project_view(frame, area),
            ZoomLevel::Thread => self.render_thread_view(frame, area),
            ZoomLevel::Event => self.render_event_view(frame, area),
        }
    }

    fn render_program_view(&self, frame: &mut Frame, area: Rect) {
        let program = self
            .selected_program
            .and_then(|id| self.registry.get_program(&id));
        let projects: Vec<_> = self.registry.projects().to_vec();
        let stats = self
            .selected_program
            .and_then(|id| self.registry.program_stats(&id));

        self.program_view
            .render(frame, area, program, &projects, stats.as_ref());
    }

    fn render_project_view(&self, frame: &mut Frame, area: Rect) {
        let project = self
            .selected_project
            .and_then(|id| self.registry.get_project(&id));
        let threads: Vec<_> = self.state.threads().cloned().collect();

        self.project_view.render(frame, area, project, &threads);
    }

    fn render_thread_view(&self, frame: &mut Frame, area: Rect) {
        let threads: Vec<_> = self.state.threads().collect();
        let thread = threads.get(self.selected_thread).copied();
        let events: Vec<Event> = self
            .state
            .all_events()
            .iter()
            .map(|e| (*e).clone())
            .collect();

        self.thread_view.render(frame, area, thread, &events);
    }

    fn render_event_view(&self, frame: &mut Frame, area: Rect) {
        let events: Vec<Event> = self
            .state
            .all_events()
            .iter()
            .map(|e| (*e).clone())
            .collect();
        let event: Option<Event> = events.iter().rev().nth(self.selected_event).cloned();

        // For related events, we'd need to trace the causation chain
        // For now, just show empty related events
        let related: Vec<Event> = Vec::new();

        self.event_view.render(frame, area, event, &related);
    }

    fn render_alert_panel(&self, frame: &mut Frame, area: Rect) {
        let block = Block::default().title("Alerts").borders(Borders::ALL);

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
                .unwrap_or_else(|| "Press : for commands | 1-4 to change level".to_string()),
        };

        let paragraph = Paragraph::new(content);
        frame.render_widget(paragraph, area);
    }

    fn render_help_overlay(&self, frame: &mut Frame, area: Rect) {
        let help_text = r#"
Impel TUI - Help

Zoom Levels (1-4):
  1 - Program View  (multi-project overview)
  2 - Project View  (threads, deliverables)
  3 - Thread View   (events, temperature)
  4 - Event View    (atomic detail)

Navigation:
  j/k     - Move up/down in lists
  h/l     - Zoom out/in
  1/2/3/4 - Jump to zoom level
  Enter   - Drill down / select
  Esc     - Back / cancel
  Tab     - Switch panels (in Project view)

Commands (: to enter command mode):
  :spawn <title>  - Create new thread
  :kill           - Kill selected thread
  :priority <n>   - Set temperature (0.0-1.0)
  :project-new <name> - Create new project
  :ack            - Acknowledge alert
  :pause / :resume - Pause/resume system
  :q              - Quit

Other:
  Space   - Pause/resume system
  ?       - Toggle this help
  v       - Enter select mode
"#;

        let block = Block::default()
            .title("Help")
            .borders(Borders::ALL)
            .style(Style::default().bg(Color::Black));

        let help_area = centered_rect(70, 85, area);
        frame.render_widget(ratatui::widgets::Clear, help_area);
        let paragraph = Paragraph::new(help_text).block(block);
        frame.render_widget(paragraph, help_area);
    }

    /// Handle a key press, returns true if app should quit
    pub fn handle_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> bool {
        match self.mode {
            Mode::Normal => self.handle_normal_key(code, modifiers),
            Mode::Insert => self.handle_insert_key(code),
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
                self.status_message = Some("Select mode".to_string());
            }
            KeyCode::Char('i') => {
                self.mode = Mode::Insert;
                self.status_message = Some("Insert mode".to_string());
            }
            KeyCode::Char('?') => {
                self.show_help = !self.show_help;
            }
            KeyCode::Char('j') | KeyCode::Down => {
                self.navigate_down();
            }
            KeyCode::Char('k') | KeyCode::Up => {
                self.navigate_up();
            }
            // Zoom level keys
            KeyCode::Char('1') => {
                self.zoom_level = ZoomLevel::Program;
                self.status_message = Some("Level 1: Program View".to_string());
            }
            KeyCode::Char('2') => {
                self.zoom_level = ZoomLevel::Project;
                self.status_message = Some("Level 2: Project View".to_string());
            }
            KeyCode::Char('3') => {
                self.zoom_level = ZoomLevel::Thread;
                self.status_message = Some("Level 3: Thread View".to_string());
            }
            KeyCode::Char('4') => {
                self.zoom_level = ZoomLevel::Event;
                self.status_message = Some("Level 4: Event View".to_string());
            }
            // Zoom in (drill down)
            KeyCode::Char('l') | KeyCode::Right | KeyCode::Enter => {
                if let Some(next) = self.zoom_level.zoom_in() {
                    self.zoom_level = next;
                    self.status_message =
                        Some(format!("Level {}: {} View", next as u8, next.name()));
                }
            }
            // Zoom out
            KeyCode::Char('h') | KeyCode::Left | KeyCode::Esc => {
                if let Some(prev) = self.zoom_level.zoom_out() {
                    self.zoom_level = prev;
                    self.status_message =
                        Some(format!("Level {}: {} View", prev as u8, prev.name()));
                }
            }
            // Tab to switch panels in project view
            KeyCode::Tab => {
                if self.zoom_level == ZoomLevel::Project {
                    self.project_view.toggle_panel();
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

    fn navigate_down(&mut self) {
        match self.zoom_level {
            ZoomLevel::Program => {
                let count = self.registry.projects().len();
                self.program_view.next_project(count);
            }
            ZoomLevel::Project => {
                let thread_count = self.state.threads().count();
                let deliverable_count = self
                    .selected_project
                    .and_then(|id| self.registry.get_project(&id))
                    .map(|p| p.deliverables.len())
                    .unwrap_or(0);
                self.project_view.next_item(thread_count, deliverable_count);
            }
            ZoomLevel::Thread => {
                let count = self.state.all_events().len();
                self.thread_view.next_event(count);
            }
            ZoomLevel::Event => {
                self.event_view.scroll_down();
            }
        }

        // Also update selected thread for sidebar
        let thread_count = self.state.threads().count();
        if thread_count > 0 {
            self.selected_thread = (self.selected_thread + 1) % thread_count;
        }
    }

    fn navigate_up(&mut self) {
        match self.zoom_level {
            ZoomLevel::Program => {
                let count = self.registry.projects().len();
                self.program_view.prev_project(count);
            }
            ZoomLevel::Project => {
                let thread_count = self.state.threads().count();
                let deliverable_count = self
                    .selected_project
                    .and_then(|id| self.registry.get_project(&id))
                    .map(|p| p.deliverables.len())
                    .unwrap_or(0);
                self.project_view.prev_item(thread_count, deliverable_count);
            }
            ZoomLevel::Thread => {
                let count = self.state.all_events().len();
                self.thread_view.prev_event(count);
            }
            ZoomLevel::Event => {
                self.event_view.scroll_up();
            }
        }

        // Also update selected thread for sidebar
        let thread_count = self.state.threads().count();
        if thread_count > 0 && self.selected_thread > 0 {
            self.selected_thread -= 1;
        }
    }

    fn handle_command_key(&mut self, code: KeyCode) -> bool {
        match code {
            KeyCode::Esc => {
                self.mode = Mode::Normal;
                self.command_buffer.clear();
            }
            KeyCode::Enter => {
                let should_quit = self.execute_command();
                self.mode = Mode::Normal;
                self.command_buffer.clear();
                if should_quit {
                    return true;
                }
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
            KeyCode::Char('j') | KeyCode::Down => {
                self.navigate_down();
            }
            KeyCode::Char('k') | KeyCode::Up => {
                self.navigate_up();
            }
            _ => {}
        }
        false
    }

    fn handle_insert_key(&mut self, code: KeyCode) -> bool {
        // In insert mode, only Escape exits back to normal
        // This mode is for future text editing contexts (e.g., inline editing)
        match code {
            KeyCode::Esc => {
                self.mode = Mode::Normal;
                self.status_message = Some("Normal mode".to_string());
            }
            _ => {
                // In insert mode, keys would be passed to text input
                // For now, just show a message
                self.status_message = Some("Insert mode - press Esc to exit".to_string());
            }
        }
        false
    }

    fn execute_command(&mut self) -> bool {
        let parts: Vec<&str> = self.command_buffer.split_whitespace().collect();
        if parts.is_empty() {
            return false;
        }

        match parts[0] {
            "q" | "quit" => {
                return true;
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
            "project-new" => {
                let name = parts[1..].join(" ");
                if name.is_empty() {
                    self.status_message = Some("Usage: :project-new <name>".to_string());
                } else {
                    let project = Project::new(name.clone(), String::new());
                    let project_id = project.id;
                    self.registry.add_project(project);

                    // Add to current program if one is selected
                    if let Some(program_id) = self.selected_program {
                        if let Some(program) = self.registry.get_program_mut(&program_id) {
                            program.add_project(project_id);
                        }
                    }

                    self.selected_project = Some(project_id);
                    self.status_message = Some(format!("Project '{}' created", name));
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
            "level" => {
                if let Some(level_str) = parts.get(1) {
                    if let Ok(level) = level_str.parse::<u8>() {
                        if let Some(zoom) = ZoomLevel::from_level(level) {
                            self.zoom_level = zoom;
                            self.status_message =
                                Some(format!("Level {}: {} View", level, zoom.name()));
                        } else {
                            self.status_message = Some("Level must be 1-4".to_string());
                        }
                    }
                }
            }
            _ => {
                self.status_message = Some(format!("Unknown command: {}", parts[0]));
            }
        }
        false
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
