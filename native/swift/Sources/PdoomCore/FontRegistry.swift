// Font registry: loads the app's static TTF instances directly as CGFont/CTFont (no OS font-name
// registration, so there is no risk of colliding with system fonts or needing a PostScript name we don't
// control). Family-name scheme and F.archivo/archivoItalic/serif/mono match app/src/engine/type.ts.
import CoreText
import CoreGraphics
import Foundation

public enum FontError: Error, CustomStringConvertible {
  case load(String)
  public var description: String { if case .load(let s) = self { return s }; return "font error" }
}

private struct FontDef { let family: String; let file: String }

private let ARCHIVO_WIDTHS = [620, 750, 875, 1000, 1125, 1250]
private let ARCHIVO_WEIGHTS = [300, 500, 700, 900]

private func defs() -> [FontDef] {
  var d: [FontDef] = []
  for w in ARCHIVO_WIDTHS { for wt in ARCHIVO_WEIGHTS { d.append(FontDef(family: "Archivo-\(w)-\(wt)", file: "Archivo-w\(w)-\(wt).ttf")) } }
  for w in [750, 1000] { for wt in [400, 800] { d.append(FontDef(family: "ArchivoItalic-\(w)-\(wt)", file: "ArchivoItalic-w\(w)-\(wt).ttf")) } }
  for wt in [400, 600] {
    d.append(FontDef(family: "Cormorant-\(wt)", file: "Cormorant-\(wt).ttf"))
    d.append(FontDef(family: "CormorantItalic-\(wt)", file: "CormorantItalic-\(wt).ttf"))
  }
  for (n, f) in [("300", "Light"), ("400", "Regular"), ("500", "Medium"), ("600", "SemiBold"), ("700", "Bold")] {
    d.append(FontDef(family: "Plex-\(n)", file: "src/IBMPlexMono-\(f).ttf"))
  }
  d.append(FontDef(family: "PlexItalic-400", file: "src/IBMPlexMono-Italic.ttf"))
  return d
}

private func nearest(_ list: [Int], _ v: Int) -> Int {
  var best = list[0]
  for x in list where abs(x - v) < abs(best - v) { best = x }
  return best
}

/// Convenience family-name resolvers (type.ts's `F`).
public enum F {
  public static func archivo(_ width: Int = 100, _ weight: Int = 700) -> String {
    "Archivo-\(nearest(ARCHIVO_WIDTHS, width * 10))-\(nearest(ARCHIVO_WEIGHTS, weight))"
  }
  public static func archivoItalic(_ width: Int = 100, _ weight: Int = 800) -> String {
    "ArchivoItalic-\(width < 88 ? 750 : 1000)-\(weight < 600 ? 400 : 800)"
  }
  public static func serif(_ weight: Int = 400, _ italic: Bool = false) -> String {
    "\(italic ? "CormorantItalic" : "Cormorant")-\(weight < 500 ? 400 : 600)"
  }
  public static func mono(_ weight: Int = 400, _ italic: Bool = false) -> String {
    italic ? "PlexItalic-400" : "Plex-\(nearest([300, 400, 500, 600, 700], weight))"
  }
}

public final class FontRegistry: @unchecked Sendable {
  private var cgFonts: [String: CGFont] = [:]
  private var ctFontCache: [String: CTFont] = [:] // "family@size"

  public init(fontsDir: URL) throws {
    for d in defs() {
      let path = fontsDir.appendingPathComponent(d.file)
      guard let provider = CGDataProvider(url: path as CFURL) else {
        throw FontError.load("could not read \(path.path)")
      }
      guard let cg = CGFont(provider) else { throw FontError.load("could not parse font \(path.path)") }
      cgFonts[d.family] = cg
    }
  }

  public func ctFont(_ family: String, _ size: Double) throws -> CTFont {
    let key = "\(family)@\(size)"
    if let f = ctFontCache[key] { return f }
    guard let cg = cgFonts[family] else { throw FontError.load("font not loaded: \(family)") }
    let f = CTFontCreateWithGraphicsFont(cg, CGFloat(size), nil, nil)
    ctFontCache[key] = f
    return f
  }
}
