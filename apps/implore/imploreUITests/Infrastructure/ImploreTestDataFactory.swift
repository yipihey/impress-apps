//
//  ImploreTestDataFactory.swift
//  imploreUITests
//
//  Factory for creating test data for implore UI tests.
//

import Foundation

/// Factory for creating test content for implore UI tests
enum ImploreTestDataFactory {

    /// Sample CSV data for testing
    static let sampleCSVData = """
    x,y,z,color,size
    0.1,0.2,0.3,1.0,0.5
    0.4,0.5,0.6,2.0,0.6
    0.7,0.8,0.9,3.0,0.7
    1.0,1.1,1.2,4.0,0.8
    1.3,1.4,1.5,5.0,0.9
    """

    /// Sample field names
    static let sampleFields = ["x", "y", "z", "color", "size", "density", "mass", "velocity"]

    /// Sample selection expressions
    static let sampleSelectionExpressions = [
        "x > 0",
        "x > 0 && y < 10",
        "sphere([0, 0, 0], 1.5)",
        "zscore(density) < 3",
        "(x > 0 && y < 10) || @saved"
    ]

    /// Sample render modes
    static let renderModes = [
        "Science 2D",
        "Box 3D",
        "Art Shader"
    ]

    /// Sample colormap names
    static let colormaps = [
        "viridis",
        "plasma",
        "inferno",
        "magma",
        "cividis",
        "coolwarm",
        "spectral"
    ]

    /// Generate CSV data with specified point count
    static func generateCSVData(pointCount: Int, fieldCount: Int = 5) -> String {
        let fieldNames = sampleFields.prefix(fieldCount)
        var lines = [fieldNames.joined(separator: ",")]

        for i in 0..<pointCount {
            var values: [String] = []
            for j in 0..<fieldCount {
                let value = Double(i) * 0.1 + Double(j) * 0.01
                values.append(String(format: "%.3f", value))
            }
            lines.append(values.joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    /// Generate 3D point cloud data
    static func generate3DPointCloud(pointCount: Int) -> String {
        var lines = ["x,y,z,color"]

        for _ in 0..<pointCount {
            let x = Double.random(in: -1...1)
            let y = Double.random(in: -1...1)
            let z = Double.random(in: -1...1)
            let color = sqrt(x*x + y*y + z*z)
            lines.append(String(format: "%.4f,%.4f,%.4f,%.4f", x, y, z, color))
        }

        return lines.joined(separator: "\n")
    }
}
