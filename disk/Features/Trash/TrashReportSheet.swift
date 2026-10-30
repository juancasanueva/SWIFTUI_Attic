import SwiftUI

struct TrashReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let report: TrashReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Moved \(report.movedBytes.byteText) to the Trash").font(.title3.weight(.semibold))
            Text("These items weren't moved:").foregroundStyle(.secondary)
            List(report.failures, id: \.self) { failure in
                VStack(alignment: .leading) {
                    Text(failure.path).lineLimit(1).truncationMode(.middle)
                    Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
    }
}
