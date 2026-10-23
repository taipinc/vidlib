import CoreImage
import Foundation

struct CubeLUT {
  let dimension: Int
  let data: Data

  init(contents: String) throws {
    var size: Int?
    var values: [Float] = []
    var minimum: [Float] = [0, 0, 0]
    var maximum: [Float] = [1, 1, 1]
    for raw in contents.components(separatedBy: .newlines) {
      let line = raw.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
      let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      guard let first = parts.first else { continue }
      switch first {
      case "TITLE": continue
      case "LUT_3D_SIZE":
        guard parts.count == 2, let n = Int(parts[1]), (2...65).contains(n), size == nil else {
          throw LUTError.invalidSize
        }
        size = n
      case "DOMAIN_MIN", "DOMAIN_MAX":
        let numbers = parts.dropFirst().compactMap(Float.init)
        guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else { throw LUTError.invalidData }
        if first == "DOMAIN_MIN" { minimum = numbers } else { maximum = numbers }
      case "LUT_1D_SIZE": throw LUTError.oneDimensional
      default:
        guard parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]),
          let b = Float(parts[2]), [r, g, b].allSatisfy(\.isFinite)
        else { throw LUTError.invalidData }
        values.append(contentsOf: [r, g, b, 1])
        guard values.count <= 65 * 65 * 65 * 4 else { throw LUTError.invalidData }
      }
    }
    guard let size else { throw LUTError.invalidSize }
    guard minimum == [0, 0, 0], maximum == [1, 1, 1] else { throw LUTError.customDomain }
    guard values.count == size * size * size * 4 else { throw LUTError.invalidData }
    dimension = size
    data = values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  func apply(to image: CIImage) -> CIImage {
    // Camera LUTs expect encoded RGB, not Core Image's default linear working space.
    guard let filter = CIFilter(name: "CIColorCube") else { return image }
    filter.setValue(dimension, forKey: "inputCubeDimension")
    filter.setValue(data, forKey: "inputCubeData")
    filter.setValue(image, forKey: kCIInputImageKey)
    return filter.outputImage ?? image
  }
}

enum LUTError: LocalizedError {
  case invalidSize, invalidData, oneDimensional, customDomain
  var errorDescription: String? {
    switch self {
    case .invalidSize: return "Expected a 3D .cube LUT with a size between 2 and 65."
    case .invalidData:
      return "The LUT contains invalid values or an incorrect number of color entries."
    case .oneDimensional: return "This first version supports 3D LUTs only."
    case .customDomain:
      return "This first version supports LUTs with the standard 0–1 input domain only."
    }
  }
}
