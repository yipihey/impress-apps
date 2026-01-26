// Sample Typst document for UI testing
// This file is used as test data for imprint UI tests

= My Research Paper

#set text(font: "New Computer Modern", size: 11pt)
#set page(margin: 1in)

== Abstract

This is a sample document used for testing the imprint application.
It demonstrates various Typst features including headings, citations,
math equations, and bibliography support.

== Introduction

The field of academic writing has evolved significantly with the
introduction of modern typesetting systems. Traditional approaches
like LaTeX @knuth1986tex have been joined by newer systems such as
Typst that offer improved ergonomics and faster compilation times.

=== Background

According to recent studies @einstein1905, the efficiency of document
preparation has a significant impact on research productivity.

== Methods

Our methodology involves several key steps:

1. Document creation
2. Citation management
3. PDF compilation
4. Version control

The key equation governing our analysis is:

$ E = m c^2 $

Where $E$ is energy, $m$ is mass, and $c$ is the speed of light.

== Results

Our experiments show promising results:

#table(
  columns: (1fr, 1fr, 1fr),
  [Metric], [Value], [Unit],
  [Speed], [299792458], [m/s],
  [Mass], [1.989e30], [kg],
  [Time], [86400], [s],
)

== Discussion

The implications of these findings are significant for the broader
research community. Future work should focus on expanding the scope
of these measurements.

== Conclusion

In conclusion, we have demonstrated the utility of modern typesetting
systems for academic writing.

#bibliography("refs.bib")
