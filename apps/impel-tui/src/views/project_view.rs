//! Level 2: Project View
//!
//! Single project focus showing:
//! - Thread list with status
//! - Deliverable progress
//! - Team roster (agents)
//! - Project goals

use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Gauge, List, ListItem, Paragraph},
    Frame,
};

use impel_core::project::{Deliverable, DeliverableKind, Project, ProjectStatus};
use impel_core::thread::{Thread, ThreadState};

/// Project view state
pub struct ProjectView {
    /// Currently selected thread index within the project
    pub selected_thread: usize,
    /// Currently selected deliverable index
    pub selected_deliverable: usize,
    /// Active panel (0 = threads, 1 = deliverables)
    pub active_panel: usize,
}

impl ProjectView {
    pub fn new() -> Self {
        Self {
            selected_thread: 0,
            selected_deliverable: 0,
            active_panel: 0,
        }
    }

    /// Render the project view
    pub fn render(
        &self,
        frame: &mut Frame,
        area: Rect,
        project: Option<&Project>,
        threads: &[Thread],
    ) {
        let Some(project) = project else {
            let block = Block::default()
                .title("No Project Selected")
                .borders(Borders::ALL);
            let paragraph =
                Paragraph::new("Press 1 to go to Program view and select a project").block(block);
            frame.render_widget(paragraph, area);
            return;
        };

        // Split into header, main content, and footer
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3), // Header
                Constraint::Min(0),    // Main content
                Constraint::Length(5), // Goals
            ])
            .split(area);

        // Header with project info
        self.render_header(frame, chunks[0], project);

        // Main content: threads and deliverables
        let main_chunks = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
            .split(chunks[1]);

        self.render_thread_list(frame, main_chunks[0], project, threads);
        self.render_deliverables(frame, main_chunks[1], project);

        // Footer with goals
        self.render_goals(frame, chunks[2], project);
    }

    fn render_header(&self, frame: &mut Frame, area: Rect, project: &Project) {
        let status_style = match project.status {
            ProjectStatus::Planning => Style::default().fg(Color::Gray),
            ProjectStatus::Active => Style::default().fg(Color::Green),
            ProjectStatus::Review => Style::default().fg(Color::Magenta),
            ProjectStatus::Complete => Style::default().fg(Color::Blue),
            ProjectStatus::Paused => Style::default().fg(Color::Yellow),
            ProjectStatus::Cancelled => Style::default().fg(Color::Red),
        };

        let progress = project.overall_progress();
        let header_text = Line::from(vec![
            Span::styled(&project.name, Style::default().add_modifier(Modifier::BOLD)),
            Span::raw(" | Status: "),
            Span::styled(project.status.name(), status_style),
            Span::raw(format!(" | Progress: {:.0}%", progress * 100.0)),
            Span::raw(format!(" | {} threads", project.thread_count())),
        ]);

        let block = Block::default().borders(Borders::ALL);
        let paragraph = Paragraph::new(header_text).block(block);
        frame.render_widget(paragraph, area);
    }

    fn render_thread_list(
        &self,
        frame: &mut Frame,
        area: Rect,
        project: &Project,
        threads: &[Thread],
    ) {
        // Count threads by state
        let active_count = threads
            .iter()
            .filter(|t| t.state == ThreadState::Active)
            .count();
        let blocked_count = threads
            .iter()
            .filter(|t| t.state == ThreadState::Blocked)
            .count();
        let complete_count = threads
            .iter()
            .filter(|t| t.state == ThreadState::Complete)
            .count();

        let title = format!(
            "Threads ({}) - {} active, {} blocked, {} done",
            threads.len(),
            active_count,
            blocked_count,
            complete_count
        );

        let items: Vec<ListItem> = threads
            .iter()
            .enumerate()
            .map(|(i, thread)| {
                let state_icon = match thread.state {
                    ThreadState::Embryo => "[ ]",
                    ThreadState::Active => "[*]",
                    ThreadState::Blocked => "[!]",
                    ThreadState::Review => "[R]",
                    ThreadState::Complete => "[+]",
                    ThreadState::Killed => "[X]",
                };

                let state_color = match thread.state {
                    ThreadState::Embryo => Color::Gray,
                    ThreadState::Active => Color::Green,
                    ThreadState::Blocked => Color::Yellow,
                    ThreadState::Review => Color::Magenta,
                    ThreadState::Complete => Color::Blue,
                    ThreadState::Killed => Color::Red,
                };

                let temp_indicator = if thread.temperature.is_hot() {
                    "H"
                } else if thread.temperature.is_warm() {
                    "W"
                } else {
                    "C"
                };

                let style = if i == self.selected_thread && self.active_panel == 0 {
                    Style::default().bg(Color::DarkGray)
                } else {
                    Style::default()
                };

                ListItem::new(Line::from(vec![
                    Span::styled(format!("{} ", state_icon), Style::default().fg(state_color)),
                    Span::styled(
                        format!("[{}] ", temp_indicator),
                        Style::default().fg(Color::Cyan),
                    ),
                    Span::styled(&thread.metadata.title, style),
                ]))
            })
            .collect();

        let border_style = if self.active_panel == 0 {
            Style::default().fg(Color::Cyan)
        } else {
            Style::default()
        };

        let list = List::new(items).block(
            Block::default()
                .title(title)
                .borders(Borders::ALL)
                .border_style(border_style),
        );

        frame.render_widget(list, area);
    }

    fn render_deliverables(&self, frame: &mut Frame, area: Rect, project: &Project) {
        let deliverables = &project.deliverables;

        let items: Vec<ListItem> = deliverables
            .iter()
            .enumerate()
            .map(|(i, d)| {
                let kind_str = match &d.kind {
                    DeliverableKind::ResearchPaper { .. } => "Paper",
                    DeliverableKind::CodeRepository { .. } => "Code",
                    DeliverableKind::Dataset { .. } => "Data",
                    DeliverableKind::ReviewArticle { .. } => "Review",
                    DeliverableKind::Other { .. } => "Other",
                };

                let progress_bar = render_progress_bar(d.progress, 15);

                let style = if i == self.selected_deliverable && self.active_panel == 1 {
                    Style::default().bg(Color::DarkGray)
                } else {
                    Style::default()
                };

                let status_icon = if d.is_complete() { "[+]" } else { "[ ]" };

                ListItem::new(Line::from(vec![
                    Span::raw(format!("{} ", status_icon)),
                    Span::styled(
                        format!("{}: ", kind_str),
                        Style::default().fg(Color::Yellow),
                    ),
                    Span::styled(&d.name, style),
                    Span::raw(" "),
                    Span::styled(progress_bar, Style::default().fg(Color::Green)),
                ]))
            })
            .collect();

        let border_style = if self.active_panel == 1 {
            Style::default().fg(Color::Cyan)
        } else {
            Style::default()
        };

        let list = List::new(items).block(
            Block::default()
                .title(format!("Deliverables ({})", deliverables.len()))
                .borders(Borders::ALL)
                .border_style(border_style),
        );

        frame.render_widget(list, area);
    }

    fn render_goals(&self, frame: &mut Frame, area: Rect, project: &Project) {
        let goals_text = if project.goals.is_empty() {
            "No goals defined".to_string()
        } else {
            project
                .goals
                .iter()
                .enumerate()
                .map(|(i, g)| format!("{}. {}", i + 1, g))
                .collect::<Vec<_>>()
                .join("\n")
        };

        let block = Block::default()
            .title("Project Goals")
            .borders(Borders::ALL);

        let paragraph = Paragraph::new(goals_text).block(block);
        frame.render_widget(paragraph, area);
    }

    /// Switch active panel
    pub fn toggle_panel(&mut self) {
        self.active_panel = (self.active_panel + 1) % 2;
    }

    /// Navigate to next item in active panel
    pub fn next_item(&mut self, thread_count: usize, deliverable_count: usize) {
        match self.active_panel {
            0 => {
                if thread_count > 0 {
                    self.selected_thread = (self.selected_thread + 1) % thread_count;
                }
            }
            1 => {
                if deliverable_count > 0 {
                    self.selected_deliverable = (self.selected_deliverable + 1) % deliverable_count;
                }
            }
            _ => {}
        }
    }

    /// Navigate to previous item in active panel
    pub fn prev_item(&mut self, thread_count: usize, deliverable_count: usize) {
        match self.active_panel {
            0 => {
                if thread_count > 0 {
                    if self.selected_thread > 0 {
                        self.selected_thread -= 1;
                    } else {
                        self.selected_thread = thread_count - 1;
                    }
                }
            }
            1 => {
                if deliverable_count > 0 {
                    if self.selected_deliverable > 0 {
                        self.selected_deliverable -= 1;
                    } else {
                        self.selected_deliverable = deliverable_count - 1;
                    }
                }
            }
            _ => {}
        }
    }
}

impl Default for ProjectView {
    fn default() -> Self {
        Self::new()
    }
}

/// Render a simple ASCII progress bar
fn render_progress_bar(progress: f64, width: usize) -> String {
    let filled = (progress * width as f64).round() as usize;
    let empty = width.saturating_sub(filled);
    format!("{}{}", "=".repeat(filled), "-".repeat(empty))
}
