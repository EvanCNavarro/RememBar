import Foundation

struct RankedFileCandidate: Equatable {
    let url: URL
    let displayPath: String
    let modifiedAt: Date
    let size: Int?
    let score: Int

    var duplicateKey: String {
        "\(url.lastPathComponent.lowercased())|\(size ?? -1)"
    }

    var pathPriority: Int {
        displayPath.split(separator: "/").count * 1_000 + displayPath.count
    }
}

enum FileResultRanker {
    static func rank(urls: [URL], plan: SpotlightFileQueryPlan, home: URL, now: Date) -> [RankedFileCandidate] {
        let ranked = urls.compactMap { candidate(url: $0, plan: plan, home: home, now: now) }
        var bestByDuplicateKey: [String: RankedFileCandidate] = [:]

        for candidate in ranked {
            if let existing = bestByDuplicateKey[candidate.duplicateKey] {
                if isBetterDuplicate(candidate, than: existing) {
                    bestByDuplicateKey[candidate.duplicateKey] = candidate
                }
            } else {
                bestByDuplicateKey[candidate.duplicateKey] = candidate
            }
        }

        return bestByDuplicateKey.values.sorted(by: isBetter)
    }

    private static func candidate(
        url: URL,
        plan: SpotlightFileQueryPlan,
        home: URL,
        now: Date
    ) -> RankedFileCandidate? {
        let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey
        ])
        if values?.isRegularFile == false {
            return nil
        }

        let ext = url.pathExtension.lowercased()
        if !plan.allowedExtensions.isEmpty, !plan.allowedExtensions.contains(ext) {
            return nil
        }

        let displayPath = displayPath(for: url, home: home)
        let score = score(
            url: url,
            displayPath: displayPath,
            plan: plan,
            modifiedAt: values?.contentModificationDate,
            now: now
        )
        guard score > 0 else { return nil }

        return RankedFileCandidate(
            url: url,
            displayPath: displayPath,
            modifiedAt: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
            size: values?.fileSize,
            score: score
        )
    }

    private static func score(
        url: URL,
        displayPath: String,
        plan: SpotlightFileQueryPlan,
        modifiedAt: Date?,
        now: Date
    ) -> Int {
        let fileName = url.lastPathComponent.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let nameTerms = Set(MemorySearchTokenizer.tokenize(fileName))
        let path = displayPath.lowercased()

        let entity = entityScore(
            terms: plan.entityTerms,
            stem: stem,
            nameTerms: nameTerms,
            fileName: fileName,
            path: path
        )
        let descriptor = descriptorScore(
            terms: plan.descriptorTerms,
            stem: stem,
            nameTerms: nameTerms,
            fileName: fileName,
            path: path
        )
        var score = entity.score + descriptor.score

        if !plan.entityTerms.isEmpty, entity.matched == 0 {
            return 0
        }
        if plan.entityTerms.isEmpty, descriptor.matched == 0, !plan.descriptorTerms.isEmpty {
            return 0
        }

        if !plan.allowedExtensions.isEmpty {
            score += 80
        }

        if let modifiedAt {
            let ageDays = max(0, now.timeIntervalSince(modifiedAt) / 86_400)
            score += max(0, 20 - min(20, Int(ageDays / 30)))
        }

        score -= min(30, displayPath.split(separator: "/").count * 2)
        return score
    }

    private static func entityScore(
        terms: [String],
        stem: String,
        nameTerms: Set<String>,
        fileName: String,
        path: String
    ) -> (score: Int, matched: Int) {
        var score = 0
        var matched = 0
        for term in terms {
            if stem == term {
                score += 150
                matched += 1
            } else if nameTerms.contains(term) {
                score += 105
                matched += 1
            } else if fileName.contains(term) {
                score += 80
                matched += 1
            } else if path.contains(term) {
                score += 35
                matched += 1
            }
        }
        return (score, matched)
    }

    private static func descriptorScore(
        terms: [String],
        stem: String,
        nameTerms: Set<String>,
        fileName: String,
        path: String
    ) -> (score: Int, matched: Int) {
        var score = 0
        var matched = 0
        for term in terms {
            if stem == term {
                score += 25
                matched += 1
            } else if nameTerms.contains(term) {
                score += 20
                matched += 1
            } else if fileName.contains(term) {
                score += 14
                matched += 1
            } else if path.contains(term) {
                score += 6
                matched += 1
            }
        }
        return (score, matched)
    }

    private static func displayPath(for url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return path }
        return String(path.dropFirst(homePath.count + 1))
    }

    private static func isBetter(_ lhs: RankedFileCandidate, than rhs: RankedFileCandidate) -> Bool {
        if lhs.score == rhs.score {
            if lhs.pathPriority == rhs.pathPriority {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.pathPriority < rhs.pathPriority
        }
        return lhs.score > rhs.score
    }

    private static func isBetterDuplicate(_ lhs: RankedFileCandidate, than rhs: RankedFileCandidate) -> Bool {
        if lhs.pathPriority == rhs.pathPriority {
            if lhs.score == rhs.score {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.score > rhs.score
        }
        return lhs.pathPriority < rhs.pathPriority
    }
}
