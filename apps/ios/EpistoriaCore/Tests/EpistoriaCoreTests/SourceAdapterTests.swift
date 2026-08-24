import XCTest
import ZIPFoundation
@testable import EpistoriaCore

final class SourceAdapterTests: XCTestCase {
    func testYouTubeReferenceNormalizesSupportedLinksAndStartTimes() throws {
        let cases: [(String, String, Int?)] = [
            ("https://youtu.be/M7lc1UVf-VE?t=90", "M7lc1UVf-VE", 90),
            ("https://www.youtube.com/watch?v=M7lc1UVf-VE&t=1m30s", "M7lc1UVf-VE", 90),
            ("https://m.youtube.com/shorts/M7lc1UVf-VE", "M7lc1UVf-VE", nil),
            ("https://www.youtube.com/live/M7lc1UVf-VE?start=12", "M7lc1UVf-VE", 12),
            ("https://www.youtube-nocookie.com/embed/M7lc1UVf-VE", "M7lc1UVf-VE", nil),
        ]
        for (raw, expectedID, expectedStart) in cases {
            let reference = try YouTubeReference(url: XCTUnwrap(URL(string: raw)))
            XCTAssertEqual(reference.videoID, expectedID)
            XCTAssertEqual(reference.startSeconds, expectedStart)
            XCTAssertEqual(reference.canonicalURL.absoluteString, "https://www.youtube.com/watch?v=M7lc1UVf-VE")
            XCTAssertEqual(reference.embedURL.host, "www.youtube-nocookie.com")
        }
    }

    func testYouTubeReferenceRejectsUnsafeAndNonVideoLinks() throws {
        let invalid = [
            "http://youtu.be/M7lc1UVf-VE",
            "https://user:password@youtube.com/watch?v=M7lc1UVf-VE",
            "https://youtube.com:8443/watch?v=M7lc1UVf-VE",
            "https://example.com/watch?v=M7lc1UVf-VE",
            "https://youtube.com/playlist?list=PL123",
            "https://youtube.com/watch?list=PL123",
            "https://youtube.com/watch?v=too-short",
            "https://youtube.com/watch?v=M7lc1UVf-VE&t=9999999",
            "https://youtube.com/watch?v=M7lc1UVf-VE&t=1m-nope",
        ]
        for raw in invalid {
            XCTAssertThrowsError(try YouTubeReference(url: XCTUnwrap(URL(string: raw))))
        }
    }

    func testCSVAdapterParsesQuotedFieldsNewlinesBOMAndTrailingEmptyFields() throws {
        let source = "\u{FEFF}name,detail,empty\r\n\"Euler, Leonhard\",\"line one\nline two with \"\"quotes\"\"\",\r\n"
        let data = Data(source.utf8)
        let adapter = CSVSourceAdapter()

        try adapter.validate(data: data, filename: "people.csv", mimeType: "text/csv")
        let document = try adapter.parse(data: data)

        XCTAssertEqual(document.maximumColumnCount, 3)
        XCTAssertEqual(document.rows.count, 2)
        XCTAssertEqual(document.rows[0], ["name", "detail", "empty"])
        XCTAssertEqual(document.rows[1], ["Euler, Leonhard", "line one\nline two with \"quotes\"", ""])
        XCTAssertEqual(
            try adapter.extractText(data: data),
            "name\tdetail\tempty\nEuler, Leonhard\tline one line two with \"quotes\"\t"
        )
        XCTAssertEqual(try adapter.readableExport(data: data), data)
    }

    func testCSVAdapterRejectsMalformedEmptyAndOversizedInput() throws {
        let adapter = CSVSourceAdapter()

        XCTAssertThrowsError(
            try adapter.validate(
                data: Data("name,\"unterminated".utf8),
                filename: "bad.csv",
                mimeType: "text/csv"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .malformed) }
        XCTAssertThrowsError(
            try adapter.validate(data: Data("  \n".utf8), filename: "empty.csv", mimeType: "text/csv")
        ) { XCTAssertEqual($0 as? SourceAdapterError, .containsNoReadableText) }
        XCTAssertThrowsError(
            try adapter.validate(
                data: Data(repeating: 65, count: adapter.maximumBytes + 1),
                filename: "large.csv",
                mimeType: "text/csv"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .tooLarge) }
    }

    func testRegistryRoutesCSVWithoutChangingExistingTextAdapters() throws {
        let registry = SourceAdapterRegistry()

        XCTAssertEqual(try registry.adapter(for: "table.CSV").sourceType, .csv)
        XCTAssertEqual(try registry.adapter(for: "notes.md").sourceType, .markdown)
        XCTAssertEqual(try registry.adapter(for: "book.epub").sourceType, .epub)
        XCTAssertEqual(try registry.adapter(for: "paper.docx").sourceType, .docx)
        XCTAssertEqual(try registry.adapter(for: "slides.pptx").sourceType, .pptx)
        XCTAssertEqual(try registry.adapter(for: "table.xlsx").sourceType, .xlsx)
        XCTAssertEqual(try registry.adapter(for: .odt).sourceType, .odt)
        XCTAssertEqual(try registry.adapter(for: "lecture.m4a").sourceType, .audio)
        XCTAssertEqual(try registry.adapter(for: "lesson.mp4").sourceType, .video)
        XCTAssertEqual(try registry.adapter(for: .website).sourceType, .website)
        XCTAssertEqual(try registry.adapter(for: .googleDocument).sourceType, .googleDocument)
        XCTAssertEqual(try registry.adapter(for: .googleSlides).sourceType, .googleSlides)
        XCTAssertEqual(try registry.adapter(for: .googleSheet).sourceType, .googleSheet)
        XCTAssertTrue(registry.supportedExtensions.isSuperset(of: [
            "csv", "txt", "md", "html", "epub", "docx", "odt", "pptx", "odp", "xlsx", "mp4",
        ]))
    }

    func testWebSnapshotAdapterExtractsReadableTextAndExcludesInactiveContent() throws {
        let html = Data(
            """
            <!doctype html><html><head><title>Groups &amp; Symmetry</title>
            <style>.hidden { display: none }</style><script>secretTracker()</script></head>
            <body><main><h1>Group theory</h1><p>A group has an identity.</p>
            <p>Every element has an inverse &#x2208; G.</p></main></body></html>
            """.utf8
        )
        let adapter = WebSnapshotSourceAdapter()

        try adapter.validate(
            data: html,
            filename: "snapshot.epistoriaweb",
            mimeType: "text/html; charset=utf-8"
        )
        let text = try XCTUnwrap(adapter.extractText(data: html))
        XCTAssertEqual(try adapter.documentTitle(data: html), "Groups & Symmetry")
        XCTAssertTrue(text.contains("Group theory"))
        XCTAssertTrue(text.contains("A group has an identity."))
        XCTAssertTrue(text.contains("Every element has an inverse ∈ G."))
        XCTAssertFalse(text.contains("secretTracker"))
        XCTAssertFalse(text.contains("display: none"))
        XCTAssertEqual(try adapter.readableExport(data: html), Data(text.utf8))
    }

    func testWebSnapshotAdapterRejectsBinaryEmptyUnsupportedAndOversizedInput() throws {
        let adapter = WebSnapshotSourceAdapter()
        XCTAssertThrowsError(
            try adapter.validate(
                data: Data([0, 1, 2, 3]),
                filename: "bad.epistoriaweb",
                mimeType: "text/html"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .malformed) }
        XCTAssertThrowsError(
            try adapter.validate(
                data: Data("<html><script>only()</script></html>".utf8),
                filename: "empty.epistoriaweb",
                mimeType: "text/html"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .containsNoReadableText) }
        XCTAssertThrowsError(
            try adapter.validate(
                data: Data("<html><body>text</body></html>".utf8),
                filename: "wrong.epistoriaweb",
                mimeType: "application/pdf"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .unsupportedType) }
        XCTAssertThrowsError(
            try adapter.validate(
                data: Data(repeating: 65, count: adapter.maximumBytes + 1),
                filename: "large.epistoriaweb",
                mimeType: "text/html"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .tooLarge) }
    }

    func testWebSnapshotURLValidationAndDifferenceAreDeterministic() throws {
        let normalized = try WebSnapshotCaptureService.validatedURL(
            XCTUnwrap(URL(string: "HTTPS://Example.com/lesson#answer"))
        )
        XCTAssertEqual(normalized.absoluteString, "https://Example.com/lesson")
        for address in [
            "file:///tmp/private",
            "ftp://example.com/file",
            "http://example.com",
            "https://user:pass@example.com",
        ] {
            XCTAssertThrowsError(
                try WebSnapshotCaptureService.validatedURL(XCTUnwrap(URL(string: address)))
            ) { XCTAssertEqual($0 as? WebSnapshotCaptureError, .invalidURL) }
        }

        let difference = WebSnapshotDifference(
            previousText: "Definition\nOld example\nShared",
            currentText: "Definition\nNew example\nShared"
        )
        XCTAssertEqual(difference.addedParagraphCount, 1)
        XCTAssertEqual(difference.removedParagraphCount, 1)
        XCTAssertEqual(difference.addedExamples, ["New example"])
        XCTAssertEqual(difference.removedExamples, ["Old example"])
        XCTAssertFalse(difference.isUnchanged)
        XCTAssertTrue(
            WebSnapshotDifference(previousText: "Same", currentText: "Same").isUnchanged
        )
        let duplicateDifference = WebSnapshotDifference(
            previousText: "Repeated\nRepeated",
            currentText: "Repeated"
        )
        XCTAssertEqual(duplicateDifference.removedParagraphCount, 1)
    }

    func testWebSnapshotCaptureUsesBoundedHTMLResponseWithoutPersistentSessionState() async throws {
        let html = Data("<html><head><title>Topology</title></head><body><p>Compact sets</p></body></html>".utf8)
        WebSnapshotURLProtocol.setOutcome(.response(
            status: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            data: html
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSnapshotURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let requested = try XCTUnwrap(URL(string: "https://example.com/topology#proof"))
        let snapshot = try await WebSnapshotCaptureService(session: session).capture(url: requested)

        XCTAssertEqual(snapshot.requestedURL.absoluteString, "https://example.com/topology")
        XCTAssertEqual(snapshot.capturedURL.absoluteString, "https://example.com/topology")
        XCTAssertEqual(snapshot.title, "Topology")
        XCTAssertEqual(snapshot.readableText, "Compact sets")
        XCTAssertEqual(snapshot.data, html)
        XCTAssertNil(WebSnapshotURLProtocol.lastRequest?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(WebSnapshotURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testWebSnapshotCaptureMapsHTTPContentLengthAndOfflineFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSnapshotURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = WebSnapshotCaptureService(session: session)
        let url = try XCTUnwrap(URL(string: "https://example.com/page"))

        WebSnapshotURLProtocol.setOutcome(.response(
            status: 503,
            headers: ["Content-Type": "text/html"],
            data: Data("<p>Unavailable</p>".utf8)
        ))
        await assertThrowsAsync(try await service.capture(url: url)) {
            XCTAssertEqual($0 as? WebSnapshotCaptureError, .httpStatus(503))
        }

        WebSnapshotURLProtocol.setOutcome(.response(
            status: 200,
            headers: [
                "Content-Type": "text/html",
                "Content-Length": String(WebSnapshotCaptureService.maximumBytes + 1),
            ],
            data: Data("<p>Small body with invalid declared size</p>".utf8)
        ))
        await assertThrowsAsync(try await service.capture(url: url)) {
            XCTAssertEqual($0 as? WebSnapshotCaptureError, .tooLarge)
        }

        WebSnapshotURLProtocol.setOutcome(.failure(URLError(.notConnectedToInternet)))
        await assertThrowsAsync(try await service.capture(url: url)) {
            XCTAssertEqual($0 as? WebSnapshotCaptureError, .networkUnavailable)
        }
    }

    func testGoogleWorkspaceReferencesNormalizeSupportedShareLinks() throws {
        let document = try GoogleWorkspaceReference(url: XCTUnwrap(URL(
            string: "https://docs.google.com/document/d/doc_123-ABC/edit?resourcekey=key_456-DEF&usp=sharing#heading=h.1"
        )))
        XCTAssertEqual(document.kind, .document)
        XCTAssertEqual(document.fileID, "doc_123-ABC")
        XCTAssertEqual(
            document.canonicalURL.absoluteString,
            "https://docs.google.com/document/d/doc_123-ABC?resourcekey=key_456-DEF"
        )
        XCTAssertEqual(
            document.exportURL.absoluteString,
            "https://docs.google.com/document/d/doc_123-ABC/export?format=docx&resourcekey=key_456-DEF"
        )

        let slides = try GoogleWorkspaceReference(url: XCTUnwrap(URL(
            string: "https://docs.google.com/presentation/d/slides123/view"
        )))
        XCTAssertEqual(slides.kind, .slides)
        XCTAssertEqual(slides.exportURL.query, "format=pptx")

        let sheet = try GoogleWorkspaceReference(url: XCTUnwrap(URL(
            string: "https://docs.google.com/spreadsheets/d/sheet123/edit#gid=42"
        )))
        XCTAssertEqual(sheet.kind, .sheet)
        XCTAssertEqual(sheet.exportURL.query, "format=xlsx")

        for address in [
            "http://docs.google.com/document/d/file/edit",
            "https://evil.example/document/d/file/edit",
            "https://user:secret@docs.google.com/document/d/file/edit",
            "https://docs.google.com/document/file/edit",
            "https://drive.google.com/file/d/file/view",
        ] {
            XCTAssertThrowsError(
                try GoogleWorkspaceReference(url: XCTUnwrap(URL(string: address)))
            ) { XCTAssertEqual($0 as? GoogleWorkspaceCaptureError, .invalidURL) }
        }
        XCTAssertThrowsError(try GoogleWorkspaceReference(url: XCTUnwrap(URL(
            string: "https://docs.google.com/drawings/d/file/edit"
        )))) { XCTAssertEqual($0 as? GoogleWorkspaceCaptureError, .unsupportedDocument) }
    }

    func testGoogleWorkspaceAdaptersValidateEachExportAndProduceOfflineText() throws {
        let document = try docxFixture("Primary decomposition")
        let slides = try pptxFixture("Compactness theorem")
        let sheet = try xlsxFixture("Objective", "Practice")
        let cases: [(GoogleWorkspaceDocumentKind, Data, String)] = [
            (.document, document, "Primary decomposition"),
            (.slides, slides, "Slide 1\nCompactness theorem"),
            (.sheet, sheet, "Plan\nObjective\tPractice"),
        ]

        for (kind, data, expected) in cases {
            let adapter = GoogleWorkspaceSourceAdapter(kind: kind)
            try adapter.validate(data: data, filename: "capture", mimeType: "application/octet-stream")
            XCTAssertEqual(try adapter.extractText(data: data), expected)
            XCTAssertEqual(try adapter.readableExport(data: data), Data(expected.utf8))
            XCTAssertEqual(adapter.sourceType, kind.sourceType)
        }

        XCTAssertThrowsError(
            try GoogleWorkspaceSourceAdapter(kind: .document).validate(
                data: slides,
                filename: "spoofed",
                mimeType: "application/octet-stream"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .malformed) }
    }

    func testGoogleWorkspaceCaptureUsesExportEndpointWithoutCredentials() async throws {
        let data = try docxFixture("Group actions")
        WebSnapshotURLProtocol.setOutcome(.response(
            status: 200,
            headers: [
                "Content-Type": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                "Content-Disposition": "attachment; filename=\"Group Theory.docx\"",
            ],
            data: data
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSnapshotURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let snapshot = try await GoogleWorkspaceCaptureService(session: session).capture(
            url: XCTUnwrap(URL(string: "https://docs.google.com/document/d/group123/edit?usp=sharing"))
        )

        XCTAssertEqual(snapshot.kind, .document)
        XCTAssertEqual(snapshot.title, "Group Theory")
        XCTAssertEqual(snapshot.data, data)
        XCTAssertEqual(snapshot.readableText, "Group actions")
        XCTAssertEqual(
            WebSnapshotURLProtocol.lastRequest?.url?.absoluteString,
            "https://docs.google.com/document/d/group123/export?format=docx"
        )
        XCTAssertNil(WebSnapshotURLProtocol.lastRequest?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(WebSnapshotURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testGoogleWorkspaceCaptureRejectsAccessPagesOversizedAndMalformedExports() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSnapshotURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = GoogleWorkspaceCaptureService(session: session)
        let url = try XCTUnwrap(URL(string: "https://docs.google.com/spreadsheets/d/sheet123/edit"))

        WebSnapshotURLProtocol.setOutcome(.response(
            status: 200,
            headers: ["Content-Type": "text/html"],
            data: Data("<html>Sign in</html>".utf8)
        ))
        await assertThrowsAsync(try await service.capture(url: url)) {
            XCTAssertEqual($0 as? GoogleWorkspaceCaptureError, .accessDenied)
        }

        WebSnapshotURLProtocol.setOutcome(.response(
            status: 200,
            headers: [
                "Content-Type": "application/octet-stream",
                "Content-Length": String(XLSXSourceAdapter().maximumBytes + 1),
            ],
            data: Data("small".utf8)
        ))
        await assertThrowsAsync(try await service.capture(url: url)) {
            XCTAssertEqual($0 as? GoogleWorkspaceCaptureError, .tooLarge)
        }

        WebSnapshotURLProtocol.setOutcome(.response(
            status: 200,
            headers: ["Content-Type": "application/octet-stream"],
            data: Data("not a spreadsheet".utf8)
        ))
        await assertThrowsAsync(try await service.capture(url: url)) {
            XCTAssertEqual($0 as? SourceAdapterError, .malformed)
        }

        WebSnapshotURLProtocol.setOutcome(.failure(URLError(.notConnectedToInternet)))
        await assertThrowsAsync(try await service.capture(url: url)) {
            XCTAssertEqual($0 as? GoogleWorkspaceCaptureError, .networkUnavailable)
        }
    }

    func testAudioAdapterValidatesDecodableWAVAndPreservesOriginal() throws {
        let adapter = AudioSourceAdapter()
        let data = waveFixture()
        try adapter.validate(data: data, filename: "lecture.wav", mimeType: "audio/wav")
        XCTAssertEqual(try adapter.readableExport(data: data), data)
        XCTAssertNil(try adapter.extractText(data: data))
        XCTAssertTrue(adapter.supportedExtensions.isSuperset(of: ["aac", "caf", "m4a", "mp3", "wav"]))
    }

    func testAudioAdapterRejectsExtensionSpoofAndTruncation() throws {
        let adapter = AudioSourceAdapter()
        XCTAssertThrowsError(
            try adapter.validate(
                data: Data("not audio".utf8),
                filename: "spoofed.mp3",
                mimeType: "audio/mpeg"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .malformed) }
        XCTAssertThrowsError(
            try adapter.validate(
                data: waveFixture().prefix(20),
                filename: "cut.wav",
                mimeType: "audio/wav"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .malformed) }
    }

    func testVideoAdapterValidatesDecodableMP4AndPreservesOriginal() async throws {
        let adapter = VideoSourceAdapter()
        let data = videoFixture()
        try await adapter.validateForImport(data: data, filename: "lesson.mp4", mimeType: "video/mp4")
        XCTAssertEqual(try adapter.readableExport(data: data), data)
        XCTAssertNil(try adapter.extractText(data: data))
        XCTAssertEqual(adapter.supportedExtensions, ["m4v", "mov", "mp4"])
    }

    func testVideoAdapterRejectsExtensionSpoofAndTruncationBeforePlayback() async throws {
        let adapter = VideoSourceAdapter()
        await assertThrowsAsync(
            try await adapter.validateForImport(
                data: Data("not video".utf8),
                filename: "spoofed.mp4",
                mimeType: "video/mp4"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .malformed) }
        await assertThrowsAsync(
            try await adapter.validateForImport(
                data: videoFixture().prefix(100),
                filename: "cut.mp4",
                mimeType: "video/mp4"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .malformed) }
    }

    func testProtectedVideoFileStoreWritesExactBytesAndRemovesOnlyManagedFile() throws {
        let data = videoFixture()
        let url = try ProtectedVideoFileStore.write(data, filenameExtension: "mp4")
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try ProtectedVideoFileStore.remove(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("epistoria-unrelated-video-(UUID().uuidString).mp4")
        try data.write(to: unrelated, options: .atomic)
        defer { try? FileManager.default.removeItem(at: unrelated) }
        try ProtectedVideoFileStore.remove(unrelated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testPackagedDocumentAdaptersValidateAndExtractReadableText() throws {
        let docx = try archive([
            "[Content_Types].xml": contentTypes(
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
            ),
            "word/document.xml": """
                <w:document xmlns:w="word"><w:body><w:p><w:r><w:t>Factorization</w:t></w:r></w:p><w:p><w:r><w:t>Difference of squares</w:t></w:r></w:p></w:body></w:document>
                """,
        ])
        let pptx = try archive([
            "[Content_Types].xml": contentTypes(
                "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
            ),
            "ppt/presentation.xml": "<p:presentation xmlns:p=\"presentation\" xmlns:r=\"relationships\"><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId1\"/></p:sldIdLst></p:presentation>",
            "ppt/_rels/presentation.xml.rels": "<Relationships><Relationship Id=\"rId1\" Target=\"slides/slide1.xml\"/></Relationships>",
            "ppt/slides/slide1.xml": "<p:sld xmlns:p=\"presentation\" xmlns:a=\"drawing\"><a:p><a:r><a:t>Topology</a:t></a:r></a:p></p:sld>",
        ])
        let odt = try archive([
            "mimetype": "application/vnd.oasis.opendocument.text",
            "content.xml": "<office:document xmlns:office=\"office\" xmlns:text=\"text\"><text:p>Local compactness</text:p></office:document>",
        ])
        let odp = try archive([
            "mimetype": "application/vnd.oasis.opendocument.presentation",
            "content.xml": "<office:document xmlns:office=\"office\" xmlns:draw=\"draw\" xmlns:text=\"text\"><draw:page><text:p>First theorem</text:p></draw:page></office:document>",
        ])

        try DOCXSourceAdapter().validate(data: docx, filename: "notes.docx", mimeType: "application/octet-stream")
        XCTAssertEqual(
            try DOCXSourceAdapter().extractText(data: docx),
            "Factorization\nDifference of squares"
        )
        XCTAssertEqual(try PPTXSourceAdapter().extractText(data: pptx), "Slide 1\nTopology")
        XCTAssertEqual(try ODTSourceAdapter().extractText(data: odt), "Local compactness")
        XCTAssertEqual(try ODPSourceAdapter().extractText(data: odp), "Slide 1\nFirst theorem")
    }

    func testEPUBAndXLSXFollowReadingOrderAndSharedStrings() throws {
        let epub = try archive([
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
                <container><rootfiles><rootfile full-path="OEBPS/package.opf"/></rootfiles></container>
                """,
            "OEBPS/package.opf": """
                <package><manifest><item id="chapter" href="chapter.xhtml"/></manifest><spine><itemref idref="chapter"/></spine></package>
                """,
            "OEBPS/chapter.xhtml": "<html><body><h1>Groups</h1><p>A group has an identity.</p></body></html>",
        ])
        let xlsx = try archive([
            "[Content_Types].xml": contentTypes(
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
            ),
            "xl/workbook.xml": "<workbook xmlns:r=\"relationships\"><sheets><sheet name=\"Plan\" r:id=\"rId1\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>",
            "xl/sharedStrings.xml": "<sst><si><t>Objective</t></si><si><t>Practice</t></si></sst>",
            "xl/worksheets/sheet1.xml": "<worksheet><sheetData><row><c t=\"s\"><v>0</v></c><c t=\"s\"><v>1</v></c></row><row><c><v>3</v></c><c t=\"b\"><v>1</v></c></row></sheetData></worksheet>",
        ])

        XCTAssertEqual(
            try EPUBSourceAdapter().extractText(data: epub),
            "Chapter 1\nGroups\nA group has an identity."
        )
        XCTAssertEqual(
            try XLSXSourceAdapter().extractText(data: xlsx),
            "Plan\nObjective\tPractice\n3\tTRUE"
        )
    }

    func testPackagedSourcesRejectWrongIdentityAndTraversalPaths() throws {
        let wrongIdentity = try archive([
            "[Content_Types].xml": contentTypes(
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
            ),
            "word/document.xml": "<w:document xmlns:w=\"word\"><w:p><w:t>Text</w:t></w:p></w:document>",
        ])
        XCTAssertThrowsError(
            try DOCXSourceAdapter().validate(
                data: wrongIdentity,
                filename: "spoofed.docx",
                mimeType: "application/octet-stream"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .malformed) }

        let normal = try archive([
            "[Content_Types].xml": contentTypes(
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
            ),
            "word/document.xml": "<w:document xmlns:w=\"word\"><w:p><w:t>Text</w:t></w:p></w:document>",
            "safe.txt": "blocked",
        ])
        let traversal = replacingArchivePath(in: normal, from: "safe.txt", to: "../x.txt")
        XCTAssertThrowsError(
            try DOCXSourceAdapter().validate(
                data: traversal,
                filename: "unsafe.docx",
                mimeType: "application/octet-stream"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .malformed) }
    }

    func testPackagedSourcesRejectExcessiveExpansionBeforeExtraction() throws {
        let expanded = try archive([
            "[Content_Types].xml": contentTypes(
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
            ),
            "word/document.xml": "<w:document xmlns:w=\"word\"><w:p><w:t>Text</w:t></w:p></w:document>",
            "word/media/repeated.bin": String(repeating: "A", count: 1_000_000),
        ])

        XCTAssertThrowsError(
            try DOCXSourceAdapter().validate(
                data: expanded,
                filename: "expanded.docx",
                mimeType: "application/octet-stream"
            )
        ) { XCTAssertEqual($0 as? SourceAdapterError, .tooLarge) }
    }

    private func contentTypes(_ mainType: String) -> String {
        "<Types><Override PartName=\"/main.xml\" ContentType=\"\(mainType)\"/></Types>"
    }

    private func docxFixture(_ text: String) throws -> Data {
        try archive([
            "[Content_Types].xml": contentTypes(
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
            ),
            "word/document.xml": "<w:document xmlns:w=\"word\"><w:body><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:body></w:document>",
        ])
    }

    private func pptxFixture(_ text: String) throws -> Data {
        try archive([
            "[Content_Types].xml": contentTypes(
                "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
            ),
            "ppt/presentation.xml": "<p:presentation xmlns:p=\"presentation\" xmlns:r=\"relationships\"><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId1\"/></p:sldIdLst></p:presentation>",
            "ppt/_rels/presentation.xml.rels": "<Relationships><Relationship Id=\"rId1\" Target=\"slides/slide1.xml\"/></Relationships>",
            "ppt/slides/slide1.xml": "<p:sld xmlns:p=\"presentation\" xmlns:a=\"drawing\"><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:sld>",
        ])
    }

    private func xlsxFixture(_ first: String, _ second: String) throws -> Data {
        try archive([
            "[Content_Types].xml": contentTypes(
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
            ),
            "xl/workbook.xml": "<workbook xmlns:r=\"relationships\"><sheets><sheet name=\"Plan\" r:id=\"rId1\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>",
            "xl/sharedStrings.xml": "<sst><si><t>\(first)</t></si><si><t>\(second)</t></si></sst>",
            "xl/worksheets/sheet1.xml": "<worksheet><sheetData><row><c t=\"s\"><v>0</v></c><c t=\"s\"><v>1</v></c></row></sheetData></worksheet>",
        ])
    }

    private func archive(_ files: [String: String]) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("epistoria-source-adapter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.zip")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, string) in files.sorted(by: { $0.key < $1.key }) {
            let data = Data(string.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
        return try Data(contentsOf: url)
    }

    private func replacingArchivePath(in data: Data, from oldPath: String, to newPath: String) -> Data {
        precondition(oldPath.utf8.count == newPath.utf8.count)
        var result = data
        let old = Data(oldPath.utf8)
        let replacement = Data(newPath.utf8)
        var lowerBound = result.startIndex
        while lowerBound < result.endIndex,
              let range = result.range(of: old, in: lowerBound..<result.endIndex)
        {
            result.replaceSubrange(range, with: replacement)
            lowerBound = range.upperBound
        }
        return result
    }

    private func waveFixture() -> Data {
        let sampleBytes = 16_000
        var data = Data("RIFF".utf8)
        data.append(contentsOf: littleEndian(UInt32(36 + sampleBytes)))
        data.append(Data("WAVEfmt ".utf8))
        data.append(contentsOf: littleEndian(UInt32(16)))
        data.append(contentsOf: littleEndian(UInt16(1)))
        data.append(contentsOf: littleEndian(UInt16(1)))
        data.append(contentsOf: littleEndian(UInt32(8_000)))
        data.append(contentsOf: littleEndian(UInt32(16_000)))
        data.append(contentsOf: littleEndian(UInt16(2)))
        data.append(contentsOf: littleEndian(UInt16(16)))
        data.append(Data("data".utf8))
        data.append(contentsOf: littleEndian(UInt32(sampleBytes)))
        data.append(Data(repeating: 0, count: sampleBytes))
        return data
    }

    private func videoFixture() -> Data {
        Data(base64Encoded: Self.videoFixtureBase64)!
    }

    private static let videoFixtureBase64 = "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAN0bW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAMgAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAp90cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAMgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAADIAAAEAAABAAAAAAIXbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAyAAAACgBVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABwm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAYJzdGJsAAAAvnN0c2QAAAAAAAAAAQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMSBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAANGF2Y0MBZAAK/+EAF2dkAAqs2V7ARAAAAwAEAAADAMg8SJZYAQAGaOvjyyLA/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAHZIAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAFAAACAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAOGN0dHMAAAAAAAAABQAAAAEAAAQAAAAAAQAACgAAAAABAAAEAAAAAAEAAAAAAAAAAQAAAgAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAUAAAABAAAAKHN0c3oAAAAAAAAAAAAAAAUAAALFAAAADAAAAAwAAAAMAAAADAAAABRzdGNvAAAAAAAAAAEAAAOkAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMQAAAAhmcmVlAAAC/W1kYXQAAAKuBgX//6rcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MiBrZXlpbnQ9MjUwIGtleWludF9taW49MjUgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAAPZYiEADP//vbsvgU2FMjBAAAACEGaJGxCv/7AAAAACEGeQniF/8GBAAAACAGeYXRCv8SAAAAACAGeY2pCv8SB"

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private func assertThrowsAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ errorHandler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw")
        } catch {
            errorHandler(error)
        }
    }

}

private final class WebSnapshotURLProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome: Sendable {
        case response(status: Int, headers: [String: String], data: Data)
        case failure(URLError)
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var outcome: Outcome = .failure(URLError(.notConnectedToInternet))
        var request: URLRequest?
    }

    private static let state = State()

    static var lastRequest: URLRequest? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.request
    }

    static func setOutcome(_ outcome: Outcome) {
        state.lock.lock()
        state.outcome = outcome
        state.request = nil
        state.lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.lock.lock()
        Self.state.request = request
        let outcome = Self.state.outcome
        Self.state.lock.unlock()
        switch outcome {
        case let .response(status, headers, data):
            guard let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
