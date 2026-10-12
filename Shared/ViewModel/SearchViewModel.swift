//
//  SearchViewModel.swift
//  Cronica
//
//  Created by Alexandre Madeira on 06/03/22.
//

import Foundation
import SwiftUI

@MainActor final class SearchViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet {
            if query != oldValue {
                invalidateSearch()
                queryRevision = UUID()
            }
        }
    }
    @Published private(set) var queryRevision = UUID()
    private let searchItems: @MainActor (String, String) async throws -> [SearchItemContent]
    private let fetchKeywords: @MainActor (MediaType, Int) async throws -> [ItemContentKeyword]
    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var page = 1
    @Published var items = [SearchItemContent]()
    @Published var startPagination: Bool = false
    @Published var endPagination: Bool = false
    private var searchGeneration = UUID()
    private(set) var paginationTask: Task<Void, Never>?
    @Published var stage: SearchStage = .none
    @Published private(set) var catalogFailure: TMDBConnectionFailure?

    init(search: @escaping @MainActor (String, String) async throws -> [SearchItemContent] = {
        try await NetworkService.shared.search(query: $0, page: $1)
    }, fetchKeywords: @escaping @MainActor (MediaType, Int) async throws -> [ItemContentKeyword] = {
        try await NetworkService.shared.fetchKeywords(type: $0, id: $1)
    }) {
        self.searchItems = search
        self.fetchKeywords = fetchKeywords
    }

    func search(_ query: String) async {
        if Task.isCancelled { return }
        invalidateSearch()
        let generation = searchGeneration
        if query.isEmpty {
            startPagination = false
            withAnimation {
                items.removeAll()
                stage = .none
                catalogFailure = nil
            }
            return
        }
        catalogFailure = nil
        withAnimation { stage = .searching }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        do {
            try checkCancellation(for: generation)
            try await Task.sleep(nanoseconds: 300_000_000)
            try checkCancellation(for: generation)
            if !items.isEmpty {
                items.removeAll()
            }
            // restart pagination values
            page = 1
            endPagination = false
            let result = try await searchItems(trimmedQuery, "1")
            try checkCancellation(for: generation)
            let filtered: [SearchItemContent]
            if SettingsStore.shared.disableSearchFilter {
                filtered = result
            } else {
                filtered = try await filter(for: result, generation: generation)
            }
            try checkCancellation(for: generation)
            items.append(contentsOf: filtered.sorted(by: { $0.itemPopularity > $1.itemPopularity }))
            page = 2
            if self.items.isEmpty {
                withAnimation { stage = .empty }
                return
            }
            withAnimation {  stage = .success }
            startPagination = true
        } catch {
            guard generation == searchGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            catalogFailure = TMDBConnectionFailure.classify(error)
            withAnimation { stage = .failure }
            CronicaTelemetry.shared.handleMessage(error.localizedDescription,
                                                  for: "SearchViewModel.search()")
        }
    }
    
    func loadMoreItems() {
        if Task.isCancelled { return }
        if items.isEmpty { return }
        if !startPagination { return }
        if endPagination { return }
        if paginationTask != nil { return }
        let generation = searchGeneration
        let query = trimmedQuery
        let page = self.page
        paginationTask = Task {
            defer {
                if generation == searchGeneration, !Task.isCancelled {
                    paginationTask = nil
                }
            }
            do {
                try checkCancellation(for: generation)
                let result = try await searchItems(query, "\(page)")
                try checkCancellation(for: generation)
                let filtered = try await filter(for: result, generation: generation)
                try checkCancellation(for: generation)
                withAnimation {
                    self.items.append(contentsOf: filtered.sorted(by: { $0.itemPopularity > $1.itemPopularity }))
                }
                if result.isEmpty { endPagination = true }
                self.page = page + 1
            } catch {
                return
            }
        }
    }

    private func invalidateSearch() {
        searchGeneration = UUID()
        paginationTask?.cancel()
        paginationTask = nil
        startPagination = false
    }

    private func checkCancellation(for generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == searchGeneration else { throw CancellationError() }
    }
	
    private func filter(for items: [SearchItemContent], generation: UUID) async throws -> [SearchItemContent] {
        var result = [SearchItemContent]()
        for item in items {
            try checkCancellation(for: generation)
            do {
                let contentKeywords = try await fetchKeywords(item.itemContentMedia, item.id)
                try checkCancellation(for: generation)
                var keywordsArray = [Int]()
                let _: [()] = contentKeywords.map { item in
                    keywordsArray.append(item.id)
                }
                let containsNSFW = !Set(keywordsArray).isDisjoint(with: nsfwKeywords)
                if !containsNSFW {
                    result.append(item)
                }
            } catch {
                try checkCancellation(for: generation)
                if error is CancellationError { throw error }
                result.append(item)
            }
        }
        return result
    }
}

