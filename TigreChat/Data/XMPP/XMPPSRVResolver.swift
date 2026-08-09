import Foundation

enum SRVResolverError: Error, Sendable {
    case queryFailed(String)
    case noSRVRecords
    case timeout
}

struct SRVRecord: Sendable {
    let host: String
    let port: Int
    let priority: Int
    let weight: Int
    let service: String
}

enum SRVService: String {
    case xmppsClient = "xmpps-client"
    case xmppClient = "xmpp-client"
}

actor XMPPSRVResolver {

    func resolve(domain: String) async throws -> (record: SRVRecord, service: SRVService) {
        try await withThrowingTaskGroup(of: (record: SRVRecord, service: SRVService).self) { group in
            group.addTask {
                let xmppsRecords = try await self.querySRV(service: .xmppsClient, domain: domain)
                if let best = self.pickBest(xmppsRecords) { return (best, .xmppsClient) }
                let xmppRecords = try await self.querySRV(service: .xmppClient, domain: domain)
                if let best = self.pickBest(xmppRecords) { return (best, .xmppClient) }
                throw SRVResolverError.noSRVRecords
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw SRVResolverError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func querySRV(service: SRVService, domain: String) async throws -> [SRVRecord] {
        let fullName = "_\(service.rawValue)._tcp.\(domain)"
        let urlStr = "https://dns.google/resolve?name=\(fullName)&type=SRV"
        guard let url = URL(string: urlStr) else {
            throw SRVResolverError.queryFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SRVResolverError.queryFailed("HTTP error")
        }

        struct DNSAnswer: Decodable, Sendable {
            let name: String
            let type: Int
            let data: String?
        }

        struct DNSResponse: Decodable, Sendable {
            let Answer: [DNSAnswer]?
        }

        let decoded = try JSONDecoder().decode(DNSResponse.self, from: data)
        guard let answers = decoded.Answer else {
            throw SRVResolverError.noSRVRecords
        }

        var records: [SRVRecord] = []
        for answer in answers where answer.type == 33 {
            guard let data = answer.data else { continue }
            let parts = data.split(separator: " ")
            guard parts.count >= 4 else { continue }
            let priority = Int(parts[0]) ?? 0
            let weight = Int(parts[1]) ?? 0
            let port = Int(parts[2]) ?? 0
            let hostname = String(parts[3]).trimmingCharacters(in: .punctuationCharacters)
            guard !hostname.isEmpty, port > 0 else { continue }
            records.append(SRVRecord(
                host: hostname,
                port: port,
                priority: priority,
                weight: weight,
                service: service.rawValue
            ))
        }
        return records
    }

    nonisolated private func pickBest(_ records: [SRVRecord]) -> SRVRecord? {
        guard let minPrio = records.map(\.priority).min() else { return nil }
        let candidates = records.filter { $0.priority == minPrio }
        let totalWeight = candidates.reduce(0) { $0 + $1.weight }
        if totalWeight == 0 { return candidates.first }
        var r = Int.random(in: 0..<totalWeight)
        for record in candidates {
            r -= record.weight
            if r < 0 { return record }
        }
        return candidates.first
    }
}
