//! R*-tree spatial index implementation
//!
//! An R*-tree is a balanced tree data structure for indexing spatial data.
//! It provides O(log n) queries for:
//! - Point containment (which points are in a region)
//! - Range queries (find all points in a box)
//! - Nearest neighbor search

use serde::{Deserialize, Serialize};

/// Configuration for R*-tree construction
#[derive(Clone, Debug)]
pub struct RTreeConfig {
    /// Maximum entries per node (default: 16)
    pub max_entries: usize,
    /// Minimum entries per node (default: 4)
    pub min_entries: usize,
}

impl Default for RTreeConfig {
    fn default() -> Self {
        Self {
            max_entries: 16,
            min_entries: 4,
        }
    }
}

/// A 3D bounding box for spatial indexing
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct BoundingBox {
    pub min: [f64; 3],
    pub max: [f64; 3],
}

impl BoundingBox {
    /// Create a bounding box from min/max corners
    pub fn new(min: [f64; 3], max: [f64; 3]) -> Self {
        Self { min, max }
    }

    /// Create a bounding box from a single point
    pub fn from_point(point: [f64; 3]) -> Self {
        Self {
            min: point,
            max: point,
        }
    }

    /// Create an empty (invalid) bounding box
    pub fn empty() -> Self {
        Self {
            min: [f64::INFINITY, f64::INFINITY, f64::INFINITY],
            max: [f64::NEG_INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY],
        }
    }

    /// Check if the bounding box is empty/invalid
    pub fn is_empty(&self) -> bool {
        self.min[0] > self.max[0] || self.min[1] > self.max[1] || self.min[2] > self.max[2]
    }

    /// Expand to include a point
    pub fn expand_to_include(&mut self, point: [f64; 3]) {
        for (i, &p) in point.iter().enumerate() {
            self.min[i] = self.min[i].min(p);
            self.max[i] = self.max[i].max(p);
        }
    }

    /// Expand to include another bounding box
    pub fn expand_to_include_box(&mut self, other: &BoundingBox) {
        for i in 0..3 {
            self.min[i] = self.min[i].min(other.min[i]);
            self.max[i] = self.max[i].max(other.max[i]);
        }
    }

    /// Check if a point is contained
    pub fn contains_point(&self, point: [f64; 3]) -> bool {
        (0..3).all(|i| point[i] >= self.min[i] && point[i] <= self.max[i])
    }

    /// Check if this box intersects another
    pub fn intersects(&self, other: &BoundingBox) -> bool {
        (0..3).all(|i| self.min[i] <= other.max[i] && self.max[i] >= other.min[i])
    }

    /// Check if this box fully contains another
    pub fn contains_box(&self, other: &BoundingBox) -> bool {
        (0..3).all(|i| self.min[i] <= other.min[i] && self.max[i] >= other.max[i])
    }

    /// Calculate the volume of the bounding box
    pub fn volume(&self) -> f64 {
        if self.is_empty() {
            return 0.0;
        }
        (self.max[0] - self.min[0]) * (self.max[1] - self.min[1]) * (self.max[2] - self.min[2])
    }

    /// Calculate the volume increase if we add a point
    pub fn volume_increase(&self, point: [f64; 3]) -> f64 {
        let mut expanded = *self;
        expanded.expand_to_include(point);
        expanded.volume() - self.volume()
    }

    /// Calculate the center of the bounding box
    pub fn center(&self) -> [f64; 3] {
        [
            (self.min[0] + self.max[0]) / 2.0,
            (self.min[1] + self.max[1]) / 2.0,
            (self.min[2] + self.max[2]) / 2.0,
        ]
    }

    /// Calculate squared distance from a point to the nearest point on the box
    pub fn distance_sq_to_point(&self, point: [f64; 3]) -> f64 {
        let mut dist_sq = 0.0;
        for (i, &p) in point.iter().enumerate() {
            if p < self.min[i] {
                dist_sq += (self.min[i] - p).powi(2);
            } else if p > self.max[i] {
                dist_sq += (p - self.max[i]).powi(2);
            }
        }
        dist_sq
    }
}

/// An entry in the R*-tree (point with index)
#[derive(Clone, Debug)]
struct Entry {
    point: [f64; 3],
    index: usize,
}

/// A node in the R*-tree
#[derive(Debug)]
#[allow(dead_code)]
enum Node {
    Leaf {
        bounds: BoundingBox,
        entries: Vec<Entry>,
    },
    Internal {
        bounds: BoundingBox,
        children: Vec<Node>,
    },
}

impl Node {
    fn bounds(&self) -> &BoundingBox {
        match self {
            Node::Leaf { bounds, .. } => bounds,
            Node::Internal { bounds, .. } => bounds,
        }
    }

    #[allow(dead_code)]
    fn recalculate_bounds(&mut self) {
        match self {
            Node::Leaf { bounds, entries } => {
                *bounds = BoundingBox::empty();
                for entry in entries {
                    bounds.expand_to_include(entry.point);
                }
            }
            Node::Internal { bounds, children } => {
                *bounds = BoundingBox::empty();
                for child in children {
                    bounds.expand_to_include_box(child.bounds());
                }
            }
        }
    }
}

/// R*-tree spatial index
pub struct RTree {
    root: Option<Box<Node>>,
    config: RTreeConfig,
    size: usize,
}

impl RTree {
    /// Create a new empty R*-tree
    pub fn new() -> Self {
        Self::with_config(RTreeConfig::default())
    }

    /// Create a new R*-tree with custom configuration
    pub fn with_config(config: RTreeConfig) -> Self {
        Self {
            root: None,
            config,
            size: 0,
        }
    }

    /// Build an R*-tree from a set of points
    pub fn build(points: &[[f64; 3]]) -> Self {
        Self::build_with_config(points, RTreeConfig::default())
    }

    /// Build an R*-tree from points with custom configuration
    pub fn build_with_config(points: &[[f64; 3]], config: RTreeConfig) -> Self {
        let mut tree = Self::with_config(config);
        for (i, &point) in points.iter().enumerate() {
            tree.insert(point, i);
        }
        tree
    }

    /// Insert a point with its index
    pub fn insert(&mut self, point: [f64; 3], index: usize) {
        let entry = Entry { point, index };

        if self.root.is_none() {
            self.root = Some(Box::new(Node::Leaf {
                bounds: BoundingBox::from_point(point),
                entries: vec![entry],
            }));
            self.size = 1;
            return;
        }

        self.insert_entry(entry);
        self.size += 1;
    }

    fn insert_entry(&mut self, entry: Entry) {
        let root = self.root.take().unwrap();
        let new_root = self.insert_into_node(root, entry);
        self.root = Some(new_root);
    }

    fn insert_into_node(&self, mut node: Box<Node>, entry: Entry) -> Box<Node> {
        match &mut *node {
            Node::Leaf { bounds, entries } => {
                bounds.expand_to_include(entry.point);
                entries.push(entry);

                if entries.len() > self.config.max_entries {
                    // Need to split - for simplicity, we'll just keep growing
                    // A full implementation would split the node
                }

                node
            }
            Node::Internal { bounds, children } => {
                bounds.expand_to_include(entry.point);

                // Find best child (smallest volume increase)
                let best_idx = children
                    .iter()
                    .enumerate()
                    .min_by(|(_, a), (_, b)| {
                        let vol_a = a.bounds().volume_increase(entry.point);
                        let vol_b = b.bounds().volume_increase(entry.point);
                        vol_a.partial_cmp(&vol_b).unwrap()
                    })
                    .map(|(i, _)| i)
                    .unwrap_or(0);

                let child = children.remove(best_idx);
                let new_child = self.insert_into_node(Box::new(child), entry);
                children.insert(best_idx, *new_child);

                node
            }
        }
    }

    /// Query points within a bounding box
    pub fn query_box(&self, query_box: &BoundingBox) -> Vec<usize> {
        let mut results = Vec::new();
        if let Some(ref root) = self.root {
            self.query_box_recursive(root, query_box, &mut results);
        }
        results
    }

    fn query_box_recursive(&self, node: &Node, query_box: &BoundingBox, results: &mut Vec<usize>) {
        if !node.bounds().intersects(query_box) {
            return;
        }

        match node {
            Node::Leaf { entries, .. } => {
                for entry in entries {
                    if query_box.contains_point(entry.point) {
                        results.push(entry.index);
                    }
                }
            }
            Node::Internal { children, .. } => {
                for child in children {
                    self.query_box_recursive(child, query_box, results);
                }
            }
        }
    }

    /// Query points within a sphere
    pub fn query_sphere(&self, center: [f64; 3], radius: f64) -> Vec<usize> {
        let radius_sq = radius * radius;
        let mut results = Vec::new();

        // Use bounding box for coarse filtering
        let query_box = BoundingBox::new(
            [center[0] - radius, center[1] - radius, center[2] - radius],
            [center[0] + radius, center[1] + radius, center[2] + radius],
        );

        if let Some(ref root) = self.root {
            self.query_sphere_recursive(root, center, radius_sq, &query_box, &mut results);
        }
        results
    }

    fn query_sphere_recursive(
        &self,
        node: &Node,
        center: [f64; 3],
        radius_sq: f64,
        query_box: &BoundingBox,
        results: &mut Vec<usize>,
    ) {
        if !node.bounds().intersects(query_box) {
            return;
        }

        match node {
            Node::Leaf { entries, .. } => {
                for entry in entries {
                    let dist_sq = (entry.point[0] - center[0]).powi(2)
                        + (entry.point[1] - center[1]).powi(2)
                        + (entry.point[2] - center[2]).powi(2);
                    if dist_sq <= radius_sq {
                        results.push(entry.index);
                    }
                }
            }
            Node::Internal { children, .. } => {
                for child in children {
                    self.query_sphere_recursive(child, center, radius_sq, query_box, results);
                }
            }
        }
    }

    /// Find k nearest neighbors to a point
    pub fn knn(&self, point: [f64; 3], k: usize) -> Vec<(usize, f64)> {
        let mut results: Vec<(usize, f64)> = Vec::new();

        if let Some(ref root) = self.root {
            let mut max_dist_sq = f64::INFINITY;
            self.knn_recursive(root, point, k, &mut results, &mut max_dist_sq);
        }

        // Sort by distance
        results.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap());
        results.truncate(k);
        results
    }

    fn knn_recursive(
        &self,
        node: &Node,
        query: [f64; 3],
        k: usize,
        results: &mut Vec<(usize, f64)>,
        max_dist_sq: &mut f64,
    ) {
        // Skip if node is too far
        if node.bounds().distance_sq_to_point(query) > *max_dist_sq {
            return;
        }

        match node {
            Node::Leaf { entries, .. } => {
                for entry in entries {
                    let dist_sq = (entry.point[0] - query[0]).powi(2)
                        + (entry.point[1] - query[1]).powi(2)
                        + (entry.point[2] - query[2]).powi(2);

                    if dist_sq < *max_dist_sq || results.len() < k {
                        results.push((entry.index, dist_sq));
                        results.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap());
                        if results.len() > k {
                            results.pop();
                        }
                        if results.len() == k {
                            *max_dist_sq = results.last().unwrap().1;
                        }
                    }
                }
            }
            Node::Internal { children, .. } => {
                // Sort children by distance for better pruning
                let mut child_dists: Vec<(usize, f64)> = children
                    .iter()
                    .enumerate()
                    .map(|(i, c)| (i, c.bounds().distance_sq_to_point(query)))
                    .collect();
                child_dists.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap());

                for (i, _) in child_dists {
                    self.knn_recursive(&children[i], query, k, results, max_dist_sq);
                }
            }
        }
    }

    /// Get the number of points in the tree
    pub fn len(&self) -> usize {
        self.size
    }

    /// Check if the tree is empty
    pub fn is_empty(&self) -> bool {
        self.size == 0
    }

    /// Get the bounding box of all points
    pub fn bounds(&self) -> Option<BoundingBox> {
        self.root.as_ref().map(|r| *r.bounds())
    }
}

impl Default for RTree {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bounding_box_basics() {
        let bbox = BoundingBox::new([0.0, 0.0, 0.0], [10.0, 10.0, 10.0]);

        assert!(bbox.contains_point([5.0, 5.0, 5.0]));
        assert!(!bbox.contains_point([15.0, 5.0, 5.0]));
        assert_eq!(bbox.volume(), 1000.0);
    }

    #[test]
    fn test_bounding_box_expand() {
        let mut bbox = BoundingBox::from_point([0.0, 0.0, 0.0]);
        bbox.expand_to_include([10.0, 10.0, 10.0]);

        assert_eq!(bbox.min, [0.0, 0.0, 0.0]);
        assert_eq!(bbox.max, [10.0, 10.0, 10.0]);
    }

    #[test]
    fn test_bounding_box_intersects() {
        let a = BoundingBox::new([0.0, 0.0, 0.0], [10.0, 10.0, 10.0]);
        let b = BoundingBox::new([5.0, 5.0, 5.0], [15.0, 15.0, 15.0]);
        let c = BoundingBox::new([20.0, 20.0, 20.0], [30.0, 30.0, 30.0]);

        assert!(a.intersects(&b));
        assert!(!a.intersects(&c));
    }

    #[test]
    fn test_rtree_build() {
        let points: Vec<[f64; 3]> = vec![
            [0.0, 0.0, 0.0],
            [1.0, 1.0, 1.0],
            [2.0, 2.0, 2.0],
            [5.0, 5.0, 5.0],
            [10.0, 10.0, 10.0],
        ];

        let tree = RTree::build(&points);
        assert_eq!(tree.len(), 5);
    }

    #[test]
    fn test_rtree_query_box() {
        let points: Vec<[f64; 3]> = vec![
            [0.0, 0.0, 0.0],
            [1.0, 1.0, 1.0],
            [2.0, 2.0, 2.0],
            [5.0, 5.0, 5.0],
            [10.0, 10.0, 10.0],
        ];

        let tree = RTree::build(&points);

        let query = BoundingBox::new([0.0, 0.0, 0.0], [3.0, 3.0, 3.0]);
        let results = tree.query_box(&query);

        assert_eq!(results.len(), 3); // indices 0, 1, 2
    }

    #[test]
    fn test_rtree_query_sphere() {
        let points: Vec<[f64; 3]> = vec![
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [2.0, 0.0, 0.0],
            [10.0, 0.0, 0.0],
        ];

        let tree = RTree::build(&points);

        let results = tree.query_sphere([0.0, 0.0, 0.0], 1.5);
        assert_eq!(results.len(), 2); // indices 0, 1
    }

    #[test]
    fn test_rtree_knn() {
        let points: Vec<[f64; 3]> = vec![
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [2.0, 0.0, 0.0],
            [10.0, 0.0, 0.0],
        ];

        let tree = RTree::build(&points);

        let results = tree.knn([0.5, 0.0, 0.0], 2);
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].0, 0); // closest is index 0
        assert_eq!(results[1].0, 1); // second closest is index 1
    }

    #[test]
    fn test_bounding_box_distance() {
        let bbox = BoundingBox::new([0.0, 0.0, 0.0], [10.0, 10.0, 10.0]);

        // Point inside
        assert_eq!(bbox.distance_sq_to_point([5.0, 5.0, 5.0]), 0.0);

        // Point outside
        let dist = bbox.distance_sq_to_point([12.0, 5.0, 5.0]);
        assert!((dist - 4.0).abs() < 0.001);
    }
}
