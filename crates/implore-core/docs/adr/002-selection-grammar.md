# ADR-002: Vim-Inspired Selection Grammar

## Status
Accepted

## Context
Scientific visualization often requires selecting subsets of data:

- "Show particles with velocity > 100 km/s"
- "Select galaxies in redshift range 0.5 to 1.0"
- "Highlight the 1000 most massive halos"

Traditional approaches:
- **GUI dialogs**: Click-heavy, hard to reproduce
- **SQL-like syntax**: Verbose, unfamiliar to scientists
- **Python expressions**: Requires interpreter, security concerns
- **Custom DSL**: Steep learning curve

Scientists often work with Vim/Helix for code editing and are familiar with modal editing concepts: verbs + objects + modifiers.

## Decision
implore uses a **Vim-inspired selection grammar** that combines familiar programming operators with spatial awareness.

### Grammar Structure

```
<verb> <quantity> <object> [where <condition>]
```

**Verbs** (actions):
- `s` / `select`: Select matching elements
- `h` / `hide`: Hide matching elements
- `i` / `invert`: Invert selection
- `a` / `add`: Add to current selection
- `r` / `remove`: Remove from selection

**Quantities**:
- `N`: Exact count (e.g., `100`)
- `N%`: Percentage (e.g., `10%`)
- `all`: Everything
- `top N`: Highest N by some metric
- `bottom N`: Lowest N by some metric

**Objects** (what to select):
- `points`: Individual data points
- `region`: Spatial region
- `box`: Bounding box
- `sphere`: Spherical region

**Conditions**:
- Comparison: `x > 0`, `mass < 1e10`
- Range: `z in [0.5, 1.0]`
- Logic: `and`, `or`, `not`

### Examples

```
# Select 100 random points
s 100 points

# Select top 10% by mass
s top 10% points by mass

# Select points where x > 0 and y < 100
s all points where x > 0 and y < 100

# Add high-velocity particles to selection
a all points where velocity > 1000

# Select spherical region
s all points in sphere(0, 0, 0, radius=100)
```

## Consequences

### Positive
- Composable: Combine verbs, quantities, conditions freely
- Reproducible: Text commands can be saved and replayed
- Familiar: Scientists with Vim experience adapt quickly
- Expressive: Handles common selection patterns concisely
- Keyboard-driven: Minimal mouse interaction needed

### Negative
- Learning curve: Unfamiliar to non-Vim users
- Limited expressiveness: Complex selections may need multiple commands
- Parsing complexity: Grammar must handle edge cases gracefully
- Error messages: Must be helpful when syntax is wrong

## Implementation
- Grammar defined in `implore-selection/src/parser.rs`
- AST in `implore-selection/src/ast.rs`
- Evaluation in `implore-selection/src/eval.rs`
- Integrated with Helix modal editing in UI
