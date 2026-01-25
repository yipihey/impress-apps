//! Annotation operations (for undo/redo support)

use super::types::{Annotation, AnnotationColor, Rect};
use serde::{Deserialize, Serialize};

/// An operation that can be undone/redone
#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize)]
pub enum AnnotationOperation {
    Add {
        annotation: Annotation,
    },
    Remove {
        annotation: Annotation,
    },
    UpdateContent {
        annotation_id: String,
        old_content: Option<String>,
        new_content: Option<String>,
    },
    UpdateColor {
        annotation_id: String,
        old_color: AnnotationColor,
        new_color: AnnotationColor,
    },
    Move {
        annotation_id: String,
        old_rects: Vec<Rect>,
        new_rects: Vec<Rect>,
    },
}

impl AnnotationOperation {
    /// Create the inverse operation (for undo)
    pub fn inverse(&self) -> Self {
        match self {
            Self::Add { annotation } => Self::Remove {
                annotation: annotation.clone(),
            },
            Self::Remove { annotation } => Self::Add {
                annotation: annotation.clone(),
            },
            Self::UpdateContent {
                annotation_id,
                old_content,
                new_content,
            } => Self::UpdateContent {
                annotation_id: annotation_id.clone(),
                old_content: new_content.clone(),
                new_content: old_content.clone(),
            },
            Self::UpdateColor {
                annotation_id,
                old_color,
                new_color,
            } => Self::UpdateColor {
                annotation_id: annotation_id.clone(),
                old_color: new_color.clone(),
                new_color: old_color.clone(),
            },
            Self::Move {
                annotation_id,
                old_rects,
                new_rects,
            } => Self::Move {
                annotation_id: annotation_id.clone(),
                old_rects: new_rects.clone(),
                new_rects: old_rects.clone(),
            },
        }
    }
}

/// Undo/redo stack for annotation operations
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct AnnotationHistory {
    pub undo_stack: Vec<AnnotationOperation>,
    pub redo_stack: Vec<AnnotationOperation>,
    pub max_size: u32,
}

impl AnnotationHistory {
    pub fn new(max_size: u32) -> Self {
        Self {
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            max_size,
        }
    }

    pub fn push(&mut self, operation: AnnotationOperation) {
        self.undo_stack.push(operation);
        self.redo_stack.clear(); // Clear redo stack on new action

        // Limit stack size
        while self.undo_stack.len() > self.max_size as usize {
            self.undo_stack.remove(0);
        }
    }

    pub fn undo(&mut self) -> Option<AnnotationOperation> {
        if let Some(op) = self.undo_stack.pop() {
            let inverse = op.inverse();
            self.redo_stack.push(op);
            Some(inverse)
        } else {
            None
        }
    }

    pub fn redo(&mut self) -> Option<AnnotationOperation> {
        if let Some(op) = self.redo_stack.pop() {
            self.undo_stack.push(op.clone());
            Some(op)
        } else {
            None
        }
    }

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    pub fn clear(&mut self) {
        self.undo_stack.clear();
        self.redo_stack.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_operation_inverse() {
        let annotation = Annotation::new_highlight(
            "test".to_string(),
            1,
            vec![Rect::new(0.0, 0.0, 10.0, 10.0)],
            None,
        );

        let add_op = AnnotationOperation::Add {
            annotation: annotation.clone(),
        };
        let inverse = add_op.inverse();

        match inverse {
            AnnotationOperation::Remove {
                annotation: removed,
            } => {
                assert_eq!(removed.id, annotation.id);
            }
            _ => panic!("Expected Remove operation"),
        }
    }

    #[test]
    fn test_history_undo_redo() {
        let mut history = AnnotationHistory::new(10);

        let annotation = Annotation::new_highlight(
            "test".to_string(),
            1,
            vec![Rect::new(0.0, 0.0, 10.0, 10.0)],
            None,
        );

        history.push(AnnotationOperation::Add { annotation });

        assert!(history.can_undo());
        assert!(!history.can_redo());

        let undo_op = history.undo().unwrap();
        match undo_op {
            AnnotationOperation::Remove { .. } => {}
            _ => panic!("Expected Remove for undo"),
        }

        assert!(!history.can_undo());
        assert!(history.can_redo());
    }

    #[test]
    fn test_history_max_size() {
        let mut history = AnnotationHistory::new(2);

        for i in 0..5 {
            let annotation = Annotation::new_highlight(
                format!("test-{}", i),
                1,
                vec![Rect::new(0.0, 0.0, 10.0, 10.0)],
                None,
            );
            history.push(AnnotationOperation::Add { annotation });
        }

        // Should only keep the last 2 operations
        assert_eq!(history.undo_stack.len(), 2);
    }
}
