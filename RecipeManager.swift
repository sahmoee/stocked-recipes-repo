// RecipeManager.swift — a single-file macOS GUI app to manage Stocked's recipe feed
// and its GitHub repo. Like BuildBuddy: a real window with buttons.
//
// RUN IT (from the folder that holds recipes.json — your stocked-recipes repo):
//     swift RecipeManager.swift
// or double-click "Launch Recipe Manager.command".
//
// Features: rebuild the feed from free sources, add/remove custom recipes, validate,
// log in to GitHub (gh), create/connect the repo, verify everything is correct, and
// commit + push — all from the window.

import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Model (matches the app's OnlineRecipe JSON shape exactly)

struct Recipe: Codable, Identifiable {
    var id: String
    var title: String
    var category: String
    var area: String
    var instructions: String
    var imageURL: String
    var ingredients: [String]
    var measures: [String]
    var source: String
}

let SOURCE_TAG = "Community Recipes"
let RECIPES_FILE = "recipes.json"
let CUSTOM_FILE  = "custom_recipes.json"

// MARK: - IO + helpers

func loadRecipes(_ path: String) -> [Recipe] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    return (try? JSONDecoder().decode([Recipe].self, from: data)) ?? []
}

func saveRecipes(_ recipes: [Recipe], to path: String) -> Bool {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    guard let data = try? enc.encode(recipes) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
}

func normalize(_ title: String) -> String {
    let cleaned = title.lowercased().unicodeScalars.map {
        CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
    }
    return String(cleaned).split(separator: " ").joined(separator: " ")
}

func merge(_ base: [Recipe], _ incoming: [Recipe]) -> [Recipe] {
    var out = base
    var seen = Set(base.map { normalize($0.title) })
    for r in incoming {
        let key = normalize(r.title)
        guard !key.isEmpty, !seen.contains(key) else { continue }
        guard !r.title.trimmingCharacters(in: .whitespaces).isEmpty,
              !r.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        seen.insert(key); out.append(r)
    }
    return out
}

/// Loads and merges every custom*.json in the working folder (supports multiple custom files).
func loadAllCustoms() -> [Recipe] {
    let fm = FileManager.default
    let files = ((try? fm.contentsOfDirectory(atPath: fm.currentDirectoryPath)) ?? []).sorted()
    var all: [Recipe] = []
    for f in files where f.lowercased().hasPrefix("custom") && f.lowercased().hasSuffix(".json") {
        all = merge(all, loadRecipes(f))
    }
    return all
}

// MARK: - Networking (synchronous; always called off the main thread)

func fetchJSON(_ urlString: String) -> Any? {
    guard let url = URL(string: urlString) else { return nil }
    let sem = DispatchSemaphore(value: 0)
    var result: Any?
    var req = URLRequest(url: url)
    req.setValue("stocked-recipe-manager", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 20
    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let data = data { result = try? JSONSerialization.jsonObject(with: data) }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 25)
    return result
}

func fetchDummyJSON() -> [Recipe] {
    guard let root = fetchJSON("https://dummyjson.com/recipes?limit=0") as? [String: Any],
          let arr = root["recipes"] as? [[String: Any]] else { return [] }
    return arr.map { r in
        let steps = (r["instructions"] as? [String]) ?? []
        let ings = (r["ingredients"] as? [String]) ?? []
        return Recipe(id: "dummyjson-\(r["id"] as? Int ?? 0)",
                      title: r["name"] as? String ?? "",
                      category: ((r["mealType"] as? [String])?.first) ?? "",
                      area: r["cuisine"] as? String ?? "",
                      instructions: steps.joined(separator: "\n"),
                      imageURL: r["image"] as? String ?? "",
                      ingredients: ings, measures: ings.map { _ in "" }, source: SOURCE_TAG)
    }
}

func fetchMealDB(progress: (String) -> Void) -> [Recipe] {
    var out: [Recipe] = []
    for letter in "abcdefghijklmnopqrstuvwxyz" {
        guard let root = fetchJSON("https://www.themealdb.com/api/json/v1/1/search.php?f=\(letter)") as? [String: Any],
              let meals = root["meals"] as? [[String: Any]] else { continue }
        for m in meals {
            var ings: [String] = []; var meas: [String] = []
            for i in 1...20 {
                let ing = (m["strIngredient\(i)"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let mea = (m["strMeasure\(i)"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                if !ing.isEmpty { ings.append(ing); meas.append(mea) }
            }
            out.append(Recipe(id: "themealdb-\(m["idMeal"] as? String ?? UUID().uuidString)",
                              title: m["strMeal"] as? String ?? "",
                              category: m["strCategory"] as? String ?? "",
                              area: m["strArea"] as? String ?? "",
                              instructions: (m["strInstructions"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              imageURL: m["strMealThumb"] as? String ?? "",
                              ingredients: ings, measures: meas, source: SOURCE_TAG))
        }
        progress("  \(letter): \(out.count) fetched")
    }
    return out
}

// MARK: - Shell / git / gh

@discardableResult
func runShell(_ cmd: String, _ args: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = [cmd] + args
    let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
    do { try task.run() } catch { return "\(cmd): \(error.localizedDescription)" }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func runGit(_ args: [String]) -> String { runShell("git", args) }
func isGitRepo() -> Bool { runGit(["rev-parse", "--is-inside-work-tree"]).contains("true") }
func remoteURL() -> String { runGit(["config", "--get", "remote.origin.url"]) }

func ghUser() -> String? {
    let s = runShell("gh", ["auth", "status"])
    // gh prints e.g. "Logged in to github.com account sahmoee (...)"
    if let r = s.range(of: "account ") {
        let tail = s[r.upperBound...]
        let name = tail.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)
        if let name = name, !name.isEmpty { return name }
    }
    if s.lowercased().contains("logged in") { return "connected" }
    return nil
}

func rawFeedURL() -> String? {
    var url = remoteURL(); guard !url.isEmpty else { return nil }
    url = url.replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
    if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
    guard let r = url.range(of: "github.com/") else { return nil }
    return "https://raw.githubusercontent.com/\(String(url[r.upperBound...]))/main/\(RECIPES_FILE)"
}

// MARK: - Image resolution (free, no key): TheMealDB by name, then a category food photo

func foodishCategory(title: String, category: String) -> String? {
    let t = (title + " " + category).lowercased()
    if t.contains("dessert") || t.contains("cake") || t.contains("cookie") || t.contains("pie") || t.contains("sweet") { return "dessert" }
    if t.contains("pasta") || t.contains("noodle") || t.contains("spaghetti") || t.contains("lasagna") { return "pasta" }
    if t.contains("pizza") { return "pizza" }
    if t.contains("rice") || t.contains("risotto") || t.contains("biryani") { return "rice" }
    if t.contains("burger") || t.contains("sandwich") || t.contains("taco") || t.contains("wrap") { return "burger" }
    if t.contains("curry") || t.contains("masala") || t.contains("tikka") { return "butter-chicken" }
    if t.contains("samosa") || t.contains("pakora") { return "samosa" }
    return nil
}

/// Returns an image URL for a recipe, or nil. TheMealDB dish photo first, then a
/// category-matched food photo. Never returns a random unrelated photo.
func resolveImage(title: String, category: String) -> String? {
    if let q = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
       let root = fetchJSON("https://www.themealdb.com/api/json/v1/1/search.php?s=\(q)") as? [String: Any],
       let meals = root["meals"] as? [[String: Any]],
       let thumb = meals.first?["strMealThumb"] as? String, !thumb.isEmpty {
        return thumb
    }
    if let cat = foodishCategory(title: title, category: category),
       let root = fetchJSON("https://foodish-api.com/api/images/\(cat)") as? [String: Any],
       let img = root["image"] as? String, !img.isEmpty {
        return img
    }
    return nil
}

func missingImageCount(_ rs: [Recipe]) -> Int {
    rs.filter { $0.imageURL.trimmingCharacters(in: .whitespaces).isEmpty }.count
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var log: String = ""
    @Published var busy = false
    @Published var busyLabel = ""
    @Published var gh: String = "checking…"
    @Published var remote: String = ""
    @Published var feedURL: String = ""
    @Published var search = ""
    @Published var addAmount = "100"
    @Published var currentBranch = ""

    var filtered: [Recipe] {
        guard !search.isEmpty else { return recipes }
        let k = normalize(search)
        return recipes.filter { normalize($0.title).contains(k) }
    }

    func out(_ s: String) { log += (log.isEmpty ? "" : "\n") + s }

    func reload() {
        recipes = loadRecipes(RECIPES_FILE)
        remote = remoteURL()
        feedURL = rawFeedURL() ?? ""
        currentBranch = isGitRepo() ? runGit(["rev-parse", "--abbrev-ref", "HEAD"]) : ""
    }

    func refreshStatus() {
        background("Checking GitHub…") {
            let u = ghUser()
            DispatchQueue.main.async {
                self.gh = u ?? "not logged in"
                self.reload()
                self.out("Status: GitHub \(self.gh), remote \(self.remote.isEmpty ? "(none)" : self.remote)")
            }
        }
    }

    /// Runs blocking work off-main, then reloads on completion.
    private func background(_ label: String, _ work: @escaping () -> Void) {
        busy = true; busyLabel = label
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async { self.busy = false; self.busyLabel = ""; self.reload() }
        }
    }

    func rebuild() {
        background("Rebuilding feed…") {
            DispatchQueue.main.async { self.out("Rebuilding from free sources + your customs…") }
            var recipes = loadAllCustoms()
            recipes = merge(recipes, fetchDummyJSON())
            DispatchQueue.main.async { self.out("  DummyJSON merged (\(recipes.count))") }
            recipes = merge(recipes, fetchMealDB { line in DispatchQueue.main.async { self.out(line) } })
            // Fill any recipes that arrived without an image.
            var filled = 0
            for i in recipes.indices where recipes[i].imageURL.trimmingCharacters(in: .whitespaces).isEmpty {
                if let url = resolveImage(title: recipes[i].title, category: recipes[i].category) { recipes[i].imageURL = url; filled += 1 }
            }
            let ok = saveRecipes(recipes, to: RECIPES_FILE)
            DispatchQueue.main.async {
                self.out(ok ? "Wrote \(recipes.count) recipes to \(RECIPES_FILE)." : "! write failed")
                if filled > 0 { self.out("Filled \(filled) missing image(s).") }
            }
        }
    }

    func addRecipe(_ r: Recipe) {
        var customs = merge(loadRecipes(CUSTOM_FILE), [r]); _ = saveRecipes(customs, to: CUSTOM_FILE)
        var feed = merge(loadRecipes(RECIPES_FILE), [r]); _ = saveRecipes(feed, to: RECIPES_FILE)
        customs.removeAll(); feed.removeAll()
        reload(); out("Added \"\(r.title)\". Feed now has \(recipes.count).")
    }

    func remove(_ r: Recipe) {
        var feed = loadRecipes(RECIPES_FILE)
        feed.removeAll { normalize($0.title) == normalize(r.title) }
        _ = saveRecipes(feed, to: RECIPES_FILE)
        var customs = loadRecipes(CUSTOM_FILE)
        customs.removeAll { normalize($0.title) == normalize(r.title) }
        _ = saveRecipes(customs, to: CUSTOM_FILE)
        reload(); out("Removed \"\(r.title)\". Feed now has \(recipes.count).")
    }

    func validate() {
        let rs = loadRecipes(RECIPES_FILE)
        var problems = 0; var seen = Set<String>()
        for (i, r) in rs.enumerated() {
            if r.title.trimmingCharacters(in: .whitespaces).isEmpty { out("  #\(i): empty title"); problems += 1 }
            if r.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out("  #\(i) \(r.title): no steps"); problems += 1 }
            if r.ingredients.count != r.measures.count { out("  #\(i) \(r.title): ingredient/measure mismatch"); problems += 1 }
            let k = normalize(r.title)
            if seen.contains(k) { out("  #\(i) \(r.title): duplicate"); problems += 1 }
            seen.insert(k)
        }
        out(problems == 0 ? "Valid — \(rs.count) recipes, no problems." : "\(problems) problem(s) found.")
        let missing = missingImageCount(rs)
        if missing > 0 { out("\(missing) recipe(s) have no image — use Fill Images.") }
    }

    func fillMissingImages() {
        background("Filling images…") {
            var rs = loadRecipes(RECIPES_FILE)
            var filled = 0
            for i in rs.indices where rs[i].imageURL.trimmingCharacters(in: .whitespaces).isEmpty {
                let t = rs[i].title
                if let url = resolveImage(title: rs[i].title, category: rs[i].category) {
                    rs[i].imageURL = url; filled += 1
                    DispatchQueue.main.async { self.out("  + \(t)") }
                }
            }
            _ = saveRecipes(rs, to: RECIPES_FILE)
            // Keep customs in sync so re-added recipes keep their found image.
            var customs = loadRecipes(CUSTOM_FILE)
            for i in customs.indices where customs[i].imageURL.trimmingCharacters(in: .whitespaces).isEmpty {
                if let url = resolveImage(title: customs[i].title, category: customs[i].category) { customs[i].imageURL = url }
            }
            _ = saveRecipes(customs, to: CUSTOM_FILE)
            DispatchQueue.main.async { self.out("Filled \(filled) missing image(s). Remaining without image: \(missingImageCount(rs)).") }
        }
    }

    func ghLogin() {
        out("Opening a Terminal window for GitHub login… complete it there, then press Verify.")
        // gh auth login is interactive, so run it in Terminal.
        runShell("osascript", ["-e", "tell application \"Terminal\" to activate",
                               "-e", "tell application \"Terminal\" to do script \"gh auth login\""])
    }

    func connectRepo(name: String) {
        background("Connecting repo…") {
            if !isGitRepo() {
                DispatchQueue.main.async { self.out("git init…") }
                _ = runGit(["init"]); _ = runGit(["add", "-A"])
                _ = runGit(["commit", "-m", "Initial recipe feed"]); _ = runGit(["branch", "-M", "main"])
            }
            if remoteURL().isEmpty {
                let repo = name.trimmingCharacters(in: .whitespaces).isEmpty ? "stocked-recipes" : name
                DispatchQueue.main.async { self.out("Creating \(repo) via gh and pushing…") }
                let o = runShell("gh", ["repo", "create", repo, "--public", "--source=.", "--remote=origin", "--push"])
                DispatchQueue.main.async { self.out(o.isEmpty ? "(no output)" : o) }
            } else {
                DispatchQueue.main.async { self.out("Remote already set: \(remoteURL())") }
            }
            if let raw = rawFeedURL() { DispatchQueue.main.async { self.out("Feed URL: \(raw)") } }
        }
    }

    func commitPush() {
        background("Committing & pushing…") {
            guard isGitRepo() else { DispatchQueue.main.async { self.out("Not a git repo — use Connect Repo.") }; return }
            // Keep .DS_Store out of the repo.
            if !FileManager.default.fileExists(atPath: ".gitignore") {
                try? ".DS_Store\n".write(toFile: ".gitignore", atomically: true, encoding: .utf8)
            }
            let count = loadRecipes(RECIPES_FILE).count
            _ = runGit(["add", "-A"])   // stages recipes.json, custom (if present), and the tool files
            let commit = runGit(["commit", "-m", "Update recipes (\(count) total)"])
            DispatchQueue.main.async { self.out(commit.isEmpty ? "Nothing new to commit." : commit) }
            if remoteURL().isEmpty { DispatchQueue.main.async { self.out("No remote — use Connect Repo.") }; return }
            // Set upstream automatically on the first push.
            let branch = runGit(["rev-parse", "--abbrev-ref", "HEAD"])
            let upstream = runGit(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
            let needsUpstream = upstream.isEmpty || upstream.lowercased().contains("fatal") || upstream.lowercased().contains("no upstream")
            let push = needsUpstream
                ? runGit(["push", "-u", "origin", branch.isEmpty ? "main" : branch])
                : runGit(["push"])
            DispatchQueue.main.async { self.out(push.isEmpty ? "Pushed." : push) }
        }
    }

    func pull() {
        background("Pulling…") {
            let o = runGit(["pull", "--rebase"])
            DispatchQueue.main.async { self.out(o.isEmpty ? "Up to date." : o) }
        }
    }

    /// Fetches the free sources and appends only titles NOT already in the feed, up to `limit`.
    func addNewFromSources(limit: Int?) {
        background("Adding new recipes…") {
            let existing = Set(loadRecipes(RECIPES_FILE).map { normalize($0.title) })
            DispatchQueue.main.async { self.out("Fetching sources for new recipes…") }
            var pool = fetchDummyJSON()
            pool += fetchMealDB { line in DispatchQueue.main.async { self.out(line) } }
            var seen = existing
            var newOnes: [Recipe] = []
            for rec in pool {
                let k = normalize(rec.title)
                guard !k.isEmpty, !seen.contains(k),
                      !rec.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                seen.insert(k)
                var rec2 = rec
                if rec2.imageURL.isEmpty, let url = resolveImage(title: rec2.title, category: rec2.category) { rec2.imageURL = url }
                newOnes.append(rec2)
                if let limit = limit, newOnes.count >= limit { break }
            }
            var feed = loadRecipes(RECIPES_FILE)
            feed += newOnes
            _ = saveRecipes(feed, to: RECIPES_FILE)
            DispatchQueue.main.async { self.out("Added \(newOnes.count) NEW recipe(s) (skipped ones already listed). Feed now \(feed.count).") }
        }
    }

    /// Imports recipes from dropped .json files: adds new ones to the feed and keeps a
    /// per-file custom copy so they survive a rebuild.
    func importJSON(_ urls: [URL]) {
        background("Importing JSON…") {
            var feed = loadRecipes(RECIPES_FILE)
            let before = feed.count
            var files = 0
            for url in urls where url.pathExtension.lowercased() == "json" {
                let recs = loadRecipes(url.path)
                guard !recs.isEmpty else { continue }
                files += 1
                feed = merge(feed, recs)
                let customName = "custom_" + url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: " ", with: "_") + ".json"
                _ = saveRecipes(merge(loadRecipes(customName), recs), to: customName)
                DispatchQueue.main.async { self.out("  \(url.lastPathComponent): \(recs.count) recipe(s)") }
            }
            _ = saveRecipes(feed, to: RECIPES_FILE)
            DispatchQueue.main.async { self.out("Imported \(feed.count - before) new recipe(s) from \(files) file(s).") }
        }
    }

    func mergeBranch(_ name: String) {
        let branch = name.trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty else { return }
        background("Merging \(branch)…") {
            guard isGitRepo() else { DispatchQueue.main.async { self.out("Not a git repo.") }; return }
            let branches = runGit(["branch", "--all"])
            DispatchQueue.main.async { self.out("Branches:\n\(branches)") }
            let o = runGit(["merge", "--no-edit", branch])
            DispatchQueue.main.async { self.out(o.isEmpty ? "Merged \(branch)." : o) }
        }
    }

    func verify() {
        background("Verifying…") {
            var lines = ["── Verify ──"]
            lines.append(FileManager.default.fileExists(atPath: RECIPES_FILE) ? "✓ recipes.json present (\(loadRecipes(RECIPES_FILE).count))" : "✗ recipes.json missing")
            lines.append(isGitRepo() ? "✓ git repo" : "✗ not a git repo (use Connect Repo)")
            lines.append(ghUser() != nil ? "✓ GitHub logged in (\(ghUser() ?? ""))" : "✗ GitHub not logged in (use GitHub Login)")
            lines.append(remoteURL().isEmpty ? "✗ no remote set" : "✓ remote: \(remoteURL())")
            if let raw = rawFeedURL() { lines.append("→ feed URL: \(raw)") }
            DispatchQueue.main.async { lines.forEach { self.out($0) } }
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject var store = Store()
    @State private var showAdd = false
    @State private var repoName = "stocked-recipes"
    @State private var branchToMerge = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                listPane.frame(minWidth: 320)
                logPane.frame(minWidth: 360)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { store.reload(); store.refreshStatus() }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for pr in providers {
                group.enter()
                _ = pr.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url, url.pathExtension.lowercased() == "json" { urls.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { if !urls.isEmpty { store.importJSON(urls) } }
            return true
        }
        .sheet(isPresented: $showAdd) { AddRecipeSheet { store.addRecipe($0) } }
        .overlay { if store.busy { busyOverlay } }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recipe Feed Manager").font(.title2.bold())
                Spacer()
                chip("Recipes", "\(store.recipes.count)")
                chip("GitHub", store.gh)
            }
            HStack(spacing: 8) {
                Button("Rebuild") { store.rebuild() }
                Button("Add Recipe") { showAdd = true }
                Button("Validate") { store.validate() }
                Button("Fill Images") { store.fillMissingImages() }
                Divider().frame(height: 16)
                Button("GitHub Login") { store.ghLogin() }
                TextField("repo name", text: $repoName).frame(width: 130)
                Button("Connect Repo") { store.connectRepo(name: repoName) }
                Button("Commit & Push") { store.commitPush() }
                Button("Pull") { store.pull() }
                Button("Verify") { store.verify() }
            }.disabled(store.busy)
            HStack(spacing: 8) {
                Text("Add").foregroundStyle(.secondary)
                TextField("N", text: $store.addAmount).frame(width: 60)
                Button("Add N New") { store.addNewFromSources(limit: Int(store.addAmount)) }
                Text("(only recipes not already listed)").font(.caption).foregroundStyle(.secondary)
                Divider().frame(height: 16)
                Text("Branch:").foregroundStyle(.secondary)
                Text(store.currentBranch.isEmpty ? "—" : store.currentBranch).font(.caption.bold())
                TextField("branch to merge", text: $branchToMerge).frame(width: 140)
                Button("Merge") { store.mergeBranch(branchToMerge) }
                Text("· or drag .json onto the window").font(.caption).foregroundStyle(.secondary)
            }.disabled(store.busy)
            if !store.feedURL.isEmpty {
                HStack(spacing: 6) {
                    Text("Feed URL:").foregroundStyle(.secondary).font(.caption)
                    Text(store.feedURL).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.feedURL, forType: .string)
                    }.controlSize(.small)
                }
            }
        }.padding(14)
    }

    var listPane: some View {
        VStack(spacing: 0) {
            TextField("Search recipes…", text: $store.search).textFieldStyle(.roundedBorder).padding(8)
            List {
                ForEach(store.filtered) { r in
                    HStack(spacing: 10) {
                        AsyncImage(url: URL(string: r.imageURL)) { phase in
                            switch phase {
                            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                            default: ZStack { Color.gray.opacity(0.15); Image(systemName: "photo").foregroundStyle(.secondary) }
                            }
                        }
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("\(r.area) · \(r.category) · \(r.source)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) { store.remove(r) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    var logPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Clear") { store.log = "" }.controlSize(.small)
            }.padding(8)
            ScrollView {
                Text(store.log.isEmpty ? "Ready." : store.log)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
    }

    var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 10) { ProgressView(); Text(store.busyLabel).font(.callout) }
                .padding(20).background(.regularMaterial).cornerRadius(12)
        }.ignoresSafeArea()
    }

    func chip(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.caption.bold())
        }.padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.gray.opacity(0.15)).cornerRadius(6)
    }
}

struct AddRecipeSheet: View {
    var onSave: (Recipe) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var category = ""
    @State private var area = ""
    @State private var imageURL = ""
    @State private var steps = ""
    @State private var ingredients = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a recipe").font(.title3.bold())
            HStack {
                TextField("Title", text: $title)
                TextField("Category", text: $category).frame(width: 130)
                TextField("Cuisine/Area", text: $area).frame(width: 130)
            }
            TextField("Image URL (optional)", text: $imageURL)
            Text("Instructions — one step per line").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $steps).frame(height: 110).border(Color.gray.opacity(0.3))
            Text("Ingredients — one per line as  amount | ingredient").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $ingredients).frame(height: 90).border(Color.gray.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(title.isEmpty || steps.isEmpty)
            }
        }.padding(16).frame(width: 560)
    }

    func save() {
        var ings: [String] = []; var meas: [String] = []
        for line in ingredients.split(separator: "\n") {
            let parts = line.components(separatedBy: "|")
            if parts.count == 2 { meas.append(parts[0].trimmingCharacters(in: .whitespaces)); ings.append(parts[1].trimmingCharacters(in: .whitespaces)) }
            else { ings.append(line.trimmingCharacters(in: .whitespaces)); meas.append("") }
        }
        let slug = normalize(title).replacingOccurrences(of: " ", with: "-")
        let r = Recipe(id: "custom-\(slug)", title: title, category: category, area: area,
                       instructions: steps.split(separator: "\n").map(String.init).joined(separator: "\n"),
                       imageURL: imageURL, ingredients: ings, measures: meas, source: SOURCE_TAG)
        onSave(r); dismiss()
    }
}

// MARK: - Bootstrap a real window (works with `swift RecipeManager.swift`, no @main needed)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable],
                      backing: .buffered, defer: false)
window.title = "Recipe Feed Manager"
window.center()
window.contentView = NSHostingView(rootView: ContentView())
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
