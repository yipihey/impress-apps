//! Selection grammar parser using nom
//!
//! Grammar:
//! ```text
//! expr      := and_expr
//! and_expr  := or_expr ('&&' or_expr)*
//! or_expr   := not_expr ('||' not_expr)*
//! not_expr  := '!' atom | atom
//! atom      := comparison | geometric | statistical | '(' expr ')' | 'all' | 'none' | register
//! comparison:= value op value
//! op        := '<' | '<=' | '>' | '>=' | '==' | '!='
//! value     := field | number | string | function
//! function  := ident '(' args ')'
//! geometric := 'sphere' '(' point ',' number ')' | 'box' '(' point ',' point ')' | ...
//! ```

use crate::ast::*;
use nom::{
    branch::alt,
    bytes::complete::{tag, take_while, take_while1},
    character::complete::{char, multispace0},
    combinator::{map, recognize, value},
    multi::{many0, separated_list0},
    number::complete::double,
    sequence::{delimited, pair, preceded},
    IResult,
};
use thiserror::Error;

/// Parse errors
#[derive(Debug, Error)]
pub enum ParseError {
    #[error("Parse error: {0}")]
    Parse(String),

    #[error("Unexpected end of input")]
    UnexpectedEnd,

    #[error("Invalid expression: {0}")]
    InvalidExpression(String),
}

/// Parse a selection expression from a string
pub fn parse_selection(input: &str) -> Result<SelectionExpr, ParseError> {
    let input = input.trim();
    if input.is_empty() {
        return Ok(SelectionExpr::All);
    }

    match expr(input) {
        Ok(("", result)) => Ok(result),
        Ok((remaining, _)) => Err(ParseError::Parse(format!(
            "Unexpected characters at end: '{}'",
            remaining
        ))),
        Err(e) => Err(ParseError::Parse(format!("Parse error: {:?}", e))),
    }
}

/// Parse whitespace
fn ws<'a, F, O>(inner: F) -> impl FnMut(&'a str) -> IResult<&'a str, O>
where
    F: FnMut(&'a str) -> IResult<&'a str, O>,
{
    delimited(multispace0, inner, multispace0)
}

/// Parse an expression (entry point)
fn expr(input: &str) -> IResult<&str, SelectionExpr> {
    and_expr(input)
}

/// Parse AND expressions
fn and_expr(input: &str) -> IResult<&str, SelectionExpr> {
    let (input, first) = or_expr(input)?;
    let (input, rest) = many0(preceded(ws(tag("&&")), or_expr))(input)?;

    let result = rest
        .into_iter()
        .fold(first, |acc, e| SelectionExpr::and(acc, e));
    Ok((input, result))
}

/// Parse OR expressions
fn or_expr(input: &str) -> IResult<&str, SelectionExpr> {
    let (input, first) = not_expr(input)?;
    let (input, rest) = many0(preceded(ws(tag("||")), not_expr))(input)?;

    let result = rest
        .into_iter()
        .fold(first, |acc, e| SelectionExpr::or(acc, e));
    Ok((input, result))
}

/// Parse NOT expressions
fn not_expr(input: &str) -> IResult<&str, SelectionExpr> {
    alt((
        map(preceded(ws(char('!')), atom), |e| SelectionExpr::not(e)),
        atom,
    ))(input)
}

/// Parse atomic expressions
fn atom(input: &str) -> IResult<&str, SelectionExpr> {
    ws(alt((
        // Keywords
        value(SelectionExpr::All, tag("all")),
        value(SelectionExpr::None, tag("none")),
        // Parenthesized expression
        delimited(char('('), expr, char(')')),
        // Register reference @name
        map(preceded(char('@'), identifier), |name| {
            SelectionExpr::Register(name.to_string())
        }),
        // Geometric primitives
        map(geometric_primitive, SelectionExpr::Geometric),
        // Comparison (field op value)
        map(comparison, SelectionExpr::Comparison),
    )))(input)
}

/// Parse a comparison
fn comparison(input: &str) -> IResult<&str, Comparison> {
    let (input, lhs) = parse_value(input)?;
    let (input, op) = ws(comparison_op)(input)?;
    let (input, rhs) = parse_value(input)?;
    Ok((input, Comparison::new(lhs, op, rhs)))
}

/// Parse a comparison operator
fn comparison_op(input: &str) -> IResult<&str, ComparisonOp> {
    alt((
        value(ComparisonOp::Le, tag("<=")),
        value(ComparisonOp::Ge, tag(">=")),
        value(ComparisonOp::Eq, tag("==")),
        value(ComparisonOp::Ne, tag("!=")),
        value(ComparisonOp::Lt, tag("<")),
        value(ComparisonOp::Gt, tag(">")),
    ))(input)
}

/// Parse a value
fn parse_value(input: &str) -> IResult<&str, Value> {
    ws(alt((
        // Function call
        map(function_call, Value::Function),
        // Number (must come before identifier to avoid ambiguity)
        map(parse_number, Value::Number),
        // Field reference
        map(identifier, |s| Value::Field(s.to_string())),
        // String literal
        map(string_literal, |s| Value::String(s.to_string())),
    )))(input)
}

/// Parse a number (including scientific notation)
fn parse_number(input: &str) -> IResult<&str, f64> {
    double(input)
}

/// Parse an identifier (starts with letter or underscore, followed by alphanumeric or underscore)
fn identifier(input: &str) -> IResult<&str, &str> {
    recognize(pair(
        take_while1(|c: char| c.is_alphabetic() || c == '_'),
        take_while(|c: char| c.is_alphanumeric() || c == '_'),
    ))(input)
}

/// Parse a string literal
fn string_literal(input: &str) -> IResult<&str, &str> {
    alt((
        delimited(char('"'), take_while1(|c| c != '"'), char('"')),
        delimited(char('\''), take_while1(|c| c != '\''), char('\'')),
    ))(input)
}

/// Parse a function call
fn function_call(input: &str) -> IResult<&str, FunctionCall> {
    let (input, name) = identifier(input)?;
    let (input, _) = multispace0(input)?;
    let (input, args) = delimited(
        char('('),
        separated_list0(ws(char(',')), parse_value),
        char(')'),
    )(input)?;

    Ok((input, FunctionCall::new(name, args)))
}

/// Parse a geometric primitive
fn geometric_primitive(input: &str) -> IResult<&str, GeometricPrimitive> {
    alt((parse_sphere, parse_box, parse_polygon))(input)
}

/// Parse a sphere: sphere([x,y,z], r)
fn parse_sphere(input: &str) -> IResult<&str, GeometricPrimitive> {
    let (input, _) = tag("sphere")(input)?;
    let (input, _) = multispace0(input)?;
    let (input, _) = char('(')(input)?;
    let (input, center) = parse_point3(input)?;
    let (input, _) = ws(char(','))(input)?;
    let (input, radius) = parse_number(input)?;
    let (input, _) = char(')')(input)?;

    Ok((input, GeometricPrimitive::sphere(center, radius)))
}

/// Parse a box: box([x1,y1,z1], [x2,y2,z2])
fn parse_box(input: &str) -> IResult<&str, GeometricPrimitive> {
    let (input, _) = tag("box")(input)?;
    let (input, _) = multispace0(input)?;
    let (input, _) = char('(')(input)?;
    let (input, min) = parse_point3(input)?;
    let (input, _) = ws(char(','))(input)?;
    let (input, max) = parse_point3(input)?;
    let (input, _) = char(')')(input)?;

    Ok((input, GeometricPrimitive::aabb(min, max)))
}

/// Parse a polygon: polygon([x1,y1], [x2,y2], ...)
fn parse_polygon(input: &str) -> IResult<&str, GeometricPrimitive> {
    let (input, _) = tag("polygon")(input)?;
    let (input, _) = multispace0(input)?;
    let (input, _) = char('(')(input)?;
    let (input, vertices) = separated_list0(ws(char(',')), parse_point2)(input)?;
    let (input, _) = char(')')(input)?;

    Ok((input, GeometricPrimitive::Polygon { vertices }))
}

/// Parse a 3D point: [x, y, z]
fn parse_point3(input: &str) -> IResult<&str, [f64; 3]> {
    let (input, _) = ws(char('['))(input)?;
    let (input, x) = parse_number(input)?;
    let (input, _) = ws(char(','))(input)?;
    let (input, y) = parse_number(input)?;
    let (input, _) = ws(char(','))(input)?;
    let (input, z) = parse_number(input)?;
    let (input, _) = ws(char(']'))(input)?;

    Ok((input, [x, y, z]))
}

/// Parse a 2D point: [x, y]
fn parse_point2(input: &str) -> IResult<&str, [f64; 2]> {
    let (input, _) = ws(char('['))(input)?;
    let (input, x) = parse_number(input)?;
    let (input, _) = ws(char(','))(input)?;
    let (input, y) = parse_number(input)?;
    let (input, _) = ws(char(']'))(input)?;

    Ok((input, [x, y]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_comparison() {
        let result = parse_selection("x > 0").unwrap();
        match result {
            SelectionExpr::Comparison(c) => {
                assert!(matches!(c.lhs, Value::Field(ref f) if f == "x"));
                assert_eq!(c.op, ComparisonOp::Gt);
            }
            _ => panic!("Expected comparison"),
        }
    }

    #[test]
    fn test_parse_and_expression() {
        let result = parse_selection("x > 0 && y < 10").unwrap();
        assert!(matches!(result, SelectionExpr::And(_, _)));
    }

    #[test]
    fn test_parse_or_expression() {
        let result = parse_selection("x > 0 || y < 10").unwrap();
        assert!(matches!(result, SelectionExpr::Or(_, _)));
    }

    #[test]
    fn test_parse_not_expression() {
        let result = parse_selection("!x > 0").unwrap();
        assert!(matches!(result, SelectionExpr::Not(_)));
    }

    #[test]
    fn test_parse_sphere() {
        let result = parse_selection("sphere([0, 0, 0], 1.5)").unwrap();
        match result {
            SelectionExpr::Geometric(GeometricPrimitive::Sphere { center, radius }) => {
                assert_eq!(center, [0.0, 0.0, 0.0]);
                assert!((radius - 1.5).abs() < 1e-10);
            }
            _ => panic!("Expected sphere"),
        }
    }

    #[test]
    fn test_parse_box() {
        let result = parse_selection("box([0, 0, 0], [1, 1, 1])").unwrap();
        assert!(matches!(result, SelectionExpr::Geometric(GeometricPrimitive::Box { .. })));
    }

    #[test]
    fn test_parse_complex() {
        let result = parse_selection("(x > 0 && y < 10) || sphere([0,0,0], 5)").unwrap();
        assert!(matches!(result, SelectionExpr::Or(_, _)));
    }

    #[test]
    fn test_parse_all_none() {
        assert!(matches!(parse_selection("all").unwrap(), SelectionExpr::All));
        assert!(matches!(parse_selection("none").unwrap(), SelectionExpr::None));
    }

    #[test]
    fn test_parse_function() {
        let result = parse_selection("zscore(mass) < 3").unwrap();
        match result {
            SelectionExpr::Comparison(c) => {
                assert!(matches!(c.lhs, Value::Function(_)));
            }
            _ => panic!("Expected comparison with function"),
        }
    }
}
