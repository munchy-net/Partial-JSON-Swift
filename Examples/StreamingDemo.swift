import SwiftUI
import Combine
import PartialJSONSwift

struct ContentView: View {

    @StateObject private var stream = PartialJSONStream(allow: .all)

    private let tokens: [String] = [
        "{",
          "\"ti", "tle\"", ":", "\"Str", "eam", "ing ", "de", "mo\"", ",",
          "\"me", "ta\"", ":", "{",
              "\"co", "unt\"", ":", "4", "2", ",",
              "\"va", "lid\"", ":", "tr", "ue", ",",
              "\"ra", "tio\"", ":", "0.", "618", ",",
              "\"ta", "gs\"", ":", "[", "\"sw", "ift\"", ",", "\"js", "on\"", ",", "null", "]", ",",
              "\"ex", "t\"", ":", "{",
                  "\"na", "n\"", ":", "Na", "N", ",",
                  "\"po", "sInf\"", ":", "Infi", "nity", ",",
                  "\"ne", "gInf\"", ":", "-Inf", "inity",
              "}",
          "}", ",",
          "\"it", "ems\"", ":", "[",
              "{", "\"i", "d\"", ":", "1", ",", "\"na", "me\"", ":", "\"al", "pha\"", "}", ",",
              "{", "\"i", "d\"", ":", "2", ",", "\"na", "me\"", ":", "\"be", "ta\"", "}",
          "]", ",",
          "\"con", "tent\"", ":", "[",
              "\"Lor", "em ", "ips", "um ", "dol", "or ", "sit ", "am", "et, ", "cons", "ectet", "ur ",
              "adip", "iscin", "g ", "elit.\"", ",",
              "\"Sed ", "do ", "eius", "mod ", "temp", "or ", "inci", "didu", "nt ", "ut ",
              "labo", "re ", "et ", "dolo", "re ", "mag", "na ", "aliq", "ua.\"",
          "]",
        "}"
    ]

    @State private var tokenIndex = 0
    private let delay = Duration.milliseconds(120)

    private var root    : [String: Any]?   { stream.current as? [String: Any] }
    private var meta    : [String: Any]?   { root?["meta"]    as? [String: Any] }
    private var items   : [[String: Any]]? { root?["items"]   as? [[String: Any]] }
    private var content : [String]?        { root?["content"] as? [String] }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                Text(root?["title"] as? String ?? "—")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Meta").font(.headline)
                    row("count",    meta?["count"])
                    row("valid",    meta?["valid"])
                    row("ratio",    meta?["ratio"])
                    row("tags",     (meta?["tags"] as? [Any])?.map(str).joined(separator: ", "))

                    Divider()
                    Text("ext").font(.subheadline.bold())
                    let ext = meta?["ext"] as? [String: Any]
                    row("nan",    ext?["nan"])
                    row("posInf", ext?["posInf"])
                    row("negInf", ext?["negInf"])
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Items").font(.headline)
                    if let items, !items.isEmpty {
                        ForEach(items.indices, id: \.self) { i in
                            let rowObj = items[i]
                            HStack {
                                Text("#" + str(rowObj["id"])).bold()
                                Text(str(rowObj["name"]))
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    } else {
                        Text("—").foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Content").font(.headline)
                    if let paras = content, !paras.isEmpty {
                        ForEach(paras.indices, id: \.self) { i in
                            Text(paras[i])
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                        }
                    } else {
                        Text("—").foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                debugPanel
            }
            .padding()
        }
        .task { feed() }
    }

    @ViewBuilder private func row(_ key: String, _ value: Any?) -> some View {
        LabeledContent(key, value: str(value))
    }

    @ViewBuilder private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DEBUG")
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(bannerColor.opacity(0.2))
                .cornerRadius(4)

            Text("token  \(tokenIndex)/\(tokens.count)")

            if let err = stream.current as? Error {
                Text("error  \(err.localizedDescription)").foregroundColor(.red)
            }

            ScrollView {
                Text(bufferPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 100)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.2))
            )

            Button("Restart demo") { reset() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var bannerColor: Color {
        if stream.current is Error                   { return .red }
        if stream.current == nil                     { return .orange }
        if root != nil                               { return .green }
        return .yellow
    }

    private func str(_ any: Any?) -> String {
        switch any {
        case nil, is NSNull:                         return "—"
        case let d as Double where d.isNaN:          return "NaN"
        case let d as Double where d == .infinity:   return "∞"
        case let d as Double where d == -.infinity:  return "-∞"
        default:                                     return String(describing: any!)
        }
    }

    private var bufferPreview: String {
        (Mirror(reflecting: stream).children
            .first { $0.label == "buffer" }?.value as? String) ?? "∅"
    }

    private func feed() {
        Task.detached {
            for tok in tokens {
                try? await Task.sleep(for: delay)
                await MainActor.run {
                    print("⇢ token[\(tokenIndex)]: \(tok)")
                    stream.append(tok)
                    print("   ↳ snapshot:", stream.current ?? "nil")
                    tokenIndex += 1
                }
            }
        }
    }

    private func reset() {
        tokenIndex = 0
        stream.clear()
        feed()
    }
}

//#Preview { ContentView() }
