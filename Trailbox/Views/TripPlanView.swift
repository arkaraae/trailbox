import SwiftUI

struct TripPlanView: View {
    @EnvironmentObject private var model: TrailboxViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""
    @State private var contactName = ""
    @State private var contactEmail = ""
    @State private var expectedReturn = Date().addingTimeInterval(3 * 3_600)
    @State private var medical = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    TextField("Group name", text: $groupName)
                    DatePicker("Expected return", selection: $expectedReturn, in: Date()...)
                    Text("Route: Sample Hill Loop (bundled GPX)").font(.caption)
                }
                Section("Emergency contact") {
                    TextField("Name", text: $contactName)
                    TextField("Email", text: $contactEmail)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
                Section("Private medical details") {
                    TextField("Allergies, conditions, medicines, blood type", text: $medical, axis: .vertical)
                        .lineLimit(3...6)
                    Text("Saved in this iPhone's Keychain. Included only when an SOS event is recorded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if saved { Section { Text("Trip plan saved on this iPhone.").foregroundStyle(.green) } }
            }
            .navigationTitle("Trip plan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saved = model.saveTripPlan(groupName: groupName, contactName: contactName,
                                                   contactEmail: contactEmail, expectedReturn: expectedReturn,
                                                   medical: medical)
                    }
                    .disabled(groupName.isEmpty || contactName.isEmpty || !contactEmail.contains("@"))
                }
            }
            .onAppear {
                groupName = model.groupName
                contactName = model.contactName
                contactEmail = model.contactEmail
                expectedReturn = model.expectedReturn
                medical = TrailSecurity.read("medical.\(model.tripID)") ?? ""
            }
        }
    }
}
