import Contacts

@MainActor
class ContactsService: ObservableObject {
    @Published var recentAddresses: [ContactAddress] = []
    @Published var accessGranted = false

    private let store = CNContactStore()

    func requestAccess() async {
        do {
            let granted = try await store.requestAccess(for: .contacts)
            accessGranted = granted
            if granted { fetchAddresses() }
        } catch {
            accessGranted = false
        }
    }

    func fetchAddresses() {
        guard accessGranted else { return }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        var results: [ContactAddress] = []

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }

                for postal in contact.postalAddresses {
                    let addr = CNPostalAddressFormatter.string(from: postal.value, style: .mailingAddress)
                        .replacingOccurrences(of: "\n", with: ", ")
                    guard !addr.isEmpty else { continue }

                    let label = CNLabeledValue<NSString>.localizedString(forLabel: postal.label ?? "")
                    let displayName = label.isEmpty ? name : "\(name) (\(label))"
                    results.append(ContactAddress(name: displayName, address: addr))
                }
            }
        } catch { /* silently fail */ }

        // Limit to 50 most relevant (alphabetical by name)
        recentAddresses = Array(results.sorted { $0.name < $1.name }.prefix(50))
    }

    func search(_ query: String) -> [ContactAddress] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return recentAddresses.filter {
            $0.name.lowercased().contains(q) || $0.address.lowercased().contains(q)
        }
    }
}
