//! The collection tree as a pane-query [`SubtreeResolver`].
//!
//! `Scope::CollectionSubtree` compiles to "this folder and everything under
//! it" only when the compiler is handed a resolver that can read the tree.
//! The layout and surface runtimes take a resolver at construction and know
//! no collection schema; the collection kernel (`impress_core::collection_ops`)
//! is this repository's, so the resolver that reads it lives here and a host
//! passes it where it builds a service.

use std::collections::BTreeMap;
use std::sync::{Arc, OnceLock};

use impress_core::collection_ops::{
    self, CollectionSchemaBinding, FIGURE_COLLECTION, GENERIC_COLLECTION, IMBIB_COLLECTION,
    MANUSCRIPT_COLLECTION,
};
use impress_core::item::ItemId;
use impress_core::pane_query::SubtreeResolver;
use impress_core::store::AttributedStore;

/// The collection tree, flattened into a parent → children map, so
/// `Scope::CollectionSubtree` compiles to "this folder and everything under
/// it" instead of degrading to the folder's own members.
///
/// Every binding is read, because a pane's scope names a collection id and not
/// which hierarchy it belongs to — and the ids are unique across all of them,
/// so the union is unambiguous. A binding that fails to read contributes
/// nothing rather than failing the compile: a pane scoped to a collection in
/// *another* hierarchy must still resolve.
///
/// Three ways to hold it, by how long the answer may be trusted:
///
/// * [`Self::read`]: a snapshot taken now — for compiling many panes at once
///   (the FFI's invalidation feed).
/// * [`Self::lazy`]: read on the first subtree a query asks for, then kept —
///   for one compile.
/// * [`Self::live`] and [`Self::process`]: read on every subtree asked for,
///   never kept — for a resolver a service holds across calls, whose tree
///   changes between them. `process` reads the process's store
///   (`koine_store::process`), which is what the `#[impress_service]`
///   constructors, with no store of their own, compile against.
pub struct CollectionSubtrees {
    source: Source,
    children: OnceLock<BTreeMap<ItemId, Vec<ItemId>>>,
}

enum Source {
    /// A snapshot, already in `children`.
    Snapshot,
    /// Read once on first use.
    Lazy(Arc<dyn AttributedStore>),
    /// Read on every use.
    Live(Arc<dyn AttributedStore>),
    /// Read, on every use, the store this process (or this call) runs on.
    Process,
}

impl CollectionSubtrees {
    /// Read the whole tree now.
    pub fn read(store: &dyn AttributedStore) -> Self {
        let children = OnceLock::new();
        let _ = children.set(Self::scan(store));
        Self {
            source: Source::Snapshot,
            children,
        }
    }

    /// Read the tree only if a query actually asks for a subtree — most
    /// panes never do, and then this costs nothing — and keep what was read.
    pub fn lazy(store: Arc<dyn AttributedStore>) -> Self {
        Self {
            source: Source::Lazy(store),
            children: OnceLock::new(),
        }
    }

    /// Read `store`'s tree on every subtree asked for.
    pub fn live(store: Arc<dyn AttributedStore>) -> Self {
        Self {
            source: Source::Live(store),
            children: OnceLock::new(),
        }
    }

    /// Read the process's (or the current call's) store on every subtree
    /// asked for.
    pub fn process() -> Self {
        Self {
            source: Source::Process,
            children: OnceLock::new(),
        }
    }

    fn tree(&self) -> std::borrow::Cow<'_, BTreeMap<ItemId, Vec<ItemId>>> {
        use std::borrow::Cow;
        match &self.source {
            Source::Snapshot => Cow::Borrowed(self.children.get().expect("set at construction")),
            Source::Lazy(store) => {
                Cow::Borrowed(self.children.get_or_init(|| Self::scan(&**store)))
            }
            Source::Live(store) => Cow::Owned(Self::scan(&**store)),
            Source::Process => match koine_store::process::current() {
                Some(store) => Cow::Owned(Self::scan(&*store)),
                None => Cow::Owned(BTreeMap::new()),
            },
        }
    }

    fn scan(store: &dyn AttributedStore) -> BTreeMap<ItemId, Vec<ItemId>> {
        const BINDINGS: [CollectionSchemaBinding; 4] = [
            GENERIC_COLLECTION,
            IMBIB_COLLECTION,
            MANUSCRIPT_COLLECTION,
            FIGURE_COLLECTION,
        ];
        let mut children: BTreeMap<ItemId, Vec<ItemId>> = BTreeMap::new();
        for binding in BINDINGS {
            let Ok(rows) = collection_ops::list_tree_on(store, &binding) else {
                continue;
            };
            for row in rows {
                let (Ok(id), Some(Ok(parent))) = (
                    row.id.parse::<ItemId>(),
                    row.parent_id.as_deref().map(str::parse::<ItemId>),
                ) else {
                    continue;
                };
                children.entry(parent).or_default().push(id);
            }
        }
        children
    }
}

impl SubtreeResolver for CollectionSubtrees {
    fn subtree(&self, root: ItemId) -> Vec<ItemId> {
        let tree = self.tree();
        // The root is always included: a subtree contains its own root, and a
        // resolver that returned only descendants would silently drop the
        // folder's own members.
        let mut out = vec![root];
        let mut cursor = 0;
        while cursor < out.len() {
            let node = out[cursor];
            cursor += 1;
            if let Some(kids) = tree.get(&node) {
                for kid in kids {
                    if !out.contains(kid) {
                        out.push(*kid);
                    }
                }
            }
        }
        out
    }
}
