//! Level 1: Program View
//!
//! Multi-project overview showing:
//! - Project graph with relationships
//! - Global alerts by status
//! - Submission queue
//! - Agent allocation summary

use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Frame,
};

use impel_core::program::{Program, ProgramStats};
use impel_core::project::{Project, ProjectStatus};

/// Program view state
pub struct ProgramView {
    /// Currently selected project index
    pub selected_project: usize,
}

impl ProgramView {
    pub fn new() -> Self {
        Self {
            selected_project: 0,
        }
    }

    /// Render the program view
    pub fn render(
        &self,
        frame: &mut Frame,
        area: Rect,
        program: Option<&Program>,
        projects: &[Project],
        stats: Option<&ProgramStats>,
    ) {
        // Split into left panel (project list) and right panel (graph/details)
        let chunks = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
            .split(area);

        // Left panel: Project list
        self.render_project_list(frame, chunks[0], program, projects);

        // Right panel: Graph and details
        self.render_details(frame, chunks[1], projects, stats);
    }

    fn render_project_list(
        &self,
        frame: &mut Frame,
        area: Rect,
        program: Option<&Program>,
        projects: &[Project],
    ) {
        let title = program
            .map(|p| format!("Program: {} ({} projects)", p.name, projects.len()))
            .unwrap_or_else(|| "No Program".to_string());

        let items: Vec<ListItem> = projects
            .iter()
            .enumerate()
            .map(|(i, project)| {
                let status_icon = match project.status {
                    ProjectStatus::Planning => "[ ]",
                    ProjectStatus::Active => "[*]",
                    ProjectStatus::Review => "[R]",
                    ProjectStatus::Complete => "[+]",
                    ProjectStatus::Paused => "[-]",
                    ProjectStatus::Cancelled => "[X]",
                };

                let status_color = match project.status {
                    ProjectStatus::Planning => Color::Gray,
                    ProjectStatus::Active => Color::Green,
                    ProjectStatus::Review => Color::Magenta,
                    ProjectStatus::Complete => Color::Blue,
                    ProjectStatus::Paused => Color::Yellow,
                    ProjectStatus::Cancelled => Color::Red,
                };

                let style = if i == self.selected_project {
                    Style::default()
                        .bg(Color::DarkGray)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                };

                let progress = project.overall_progress();
                let progress_bar = format!(
                    "{:>3.0}% {}",
                    progress * 100.0,
                    render_progress_bar(progress, 10)
                );

                ListItem::new(Line::from(vec![
                    Span::styled(
                        format!("{} ", status_icon),
                        Style::default().fg(status_color),
                    ),
                    Span::styled(&project.name, style),
                    Span::raw(" "),
                    Span::styled(progress_bar, Style::default().fg(Color::Cyan)),
                ]))
            })
            .collect();

        let list = List::new(items)
            .block(Block::default().title(title).borders(Borders::ALL))
            .highlight_style(Style::default().bg(Color::DarkGray));

        frame.render_widget(list, area);
    }

    fn render_details(
        &self,
        frame: &mut Frame,
        area: Rect,
        projects: &[Project],
        stats: Option<&ProgramStats>,
    ) {
        // Split into stats and graph
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(8), // Stats summary
                Constraint::Min(0),    // Project graph
            ])
            .split(area);

        // Stats summary
        self.render_stats(frame, chunks[0], stats);

        // Project graph placeholder
        self.render_project_graph(frame, chunks[1], projects);
    }

    fn render_stats(&self, frame: &mut Frame, area: Rect, stats: Option<&ProgramStats>) {
        let stats_text = if let Some(s) = stats {
            format!(
                "Projects: {} total, {} active, {} complete\n\
                 Threads: {} total\n\
                 Escalations: {} open\n\
                 Submissions: {} pending\n\
                 Overall Progress: {:.0}%",
                s.project_count,
                s.active_projects,
                s.completed_projects,
                s.total_threads,
                s.open_escalations,
                s.pending_submissions,
                s.overall_progress * 100.0
            )
        } else {
            "No statistics available".to_string()
        };

        let block = Block::default()
            .title("Program Statistics")
            .borders(Borders::ALL);

        let paragraph = Paragraph::new(stats_text).block(block);
        frame.render_widget(paragraph, area);
    }

    fn render_project_graph(&self, frame: &mut Frame, area: Rect, projects: &[Project]) {
        // Simplified ASCII graph representation
        let mut lines: Vec<Line> = Vec::new();
        lines.push(Line::from("Project Relationships:"));
        lines.push(Line::from(""));

        if projects.is_empty() {
            lines.push(Line::from("  (no projects)"));
        } else {
            // Simple vertical list with status indicators
            for project in projects {
                let status_char = match project.status {
                    ProjectStatus::Active => '*',
                    ProjectStatus::Complete => '+',
                    ProjectStatus::Paused => '-',
                    _ => 'o',
                };

                lines.push(Line::from(format!(
                    "  [{}] {} ({} threads)",
                    status_char,
                    project.name,
                    project.thread_count()
                )));

                // Show relations
                for (related_id, relation) in &project.relations {
                    let relation_desc = match relation {
                        impel_core::project::ProjectRelation::FollowOn { .. } => "follows",
                        impel_core::project::ProjectRelation::Synthesis { .. } => "synthesizes",
                        impel_core::project::ProjectRelation::Sibling { .. } => "sibling of",
                        impel_core::project::ProjectRelation::Dependency { .. } => "depends on",
                    };
                    lines.push(Line::from(format!(
                        "      -> {} {}",
                        relation_desc, related_id
                    )));
                }
            }
        }

        let block = Block::default()
            .title("Project Graph")
            .borders(Borders::ALL);

        let paragraph = Paragraph::new(lines).block(block);
        frame.render_widget(paragraph, area);
    }

    /// Navigate to next project
    pub fn next_project(&mut self, project_count: usize) {
        if project_count > 0 {
            self.selected_project = (self.selected_project + 1) % project_count;
        }
    }

    /// Navigate to previous project
    pub fn prev_project(&mut self, project_count: usize) {
        if project_count > 0 {
            if self.selected_project > 0 {
                self.selected_project -= 1;
            } else {
                self.selected_project = project_count - 1;
            }
        }
    }
}

impl Default for ProgramView {
    fn default() -> Self {
        Self::new()
    }
}

/// Render a simple ASCII progress bar
fn render_progress_bar(progress: f64, width: usize) -> String {
    let filled = (progress * width as f64).round() as usize;
    let empty = width.saturating_sub(filled);
    format!("[{}{}]", "=".repeat(filled), " ".repeat(empty))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_progress_bar() {
        assert_eq!(render_progress_bar(0.0, 10), "[          ]");
        assert_eq!(render_progress_bar(0.5, 10), "[=====     ]");
        assert_eq!(render_progress_bar(1.0, 10), "[==========]");
    }
}
