import AppKit

@MainActor
final class LicenseActivationWindow: NSWindow {
    private let emailField = NSTextField()
    private let licenseKeyField = NSSecureTextField()
    private let activateButton = NSButton(title: "Lizenz aktivieren", target: nil, action: nil)
    #if !PAID_BUILD
    private let trialButton = NSButton(title: "30 Tage kostenlos testen", target: nil, action: nil)
    private let purchaseButton = NSButton(title: "Jetzt kaufen · 8,99 €", target: nil, action: nil)
    private let checkoutURL = URL(string: "https://old-launchpad.lemonsqueezy.com/checkout/buy/937768e9-7a15-4015-b7bd-3229686c771f")!
    #endif
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let onAccessGranted: () -> Void

    init(onAccessGranted: @escaping () -> Void) {
        self.onAccessGranted = onAccessGranted
        #if PAID_BUILD
        let windowHeight: CGFloat = 306
        #else
        let windowHeight: CGFloat = 404
        #endif
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: windowHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        title = "Old Launchpad aktivieren"
        isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: windowHeight))
        contentView = content

        let heading = NSTextField(labelWithString: "Lizenz aktivieren")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(heading)

        let emailLabel = NSTextField(labelWithString: "E-Mail-Adresse")
        emailLabel.translatesAutoresizingMaskIntoConstraints = false
        emailField.placeholderString = "name@example.com"
        emailField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emailLabel)
        content.addSubview(emailField)

        let keyLabel = NSTextField(labelWithString: "Lizenzschlüssel")
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        licenseKeyField.placeholderString = "Lizenzschlüssel"
        licenseKeyField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(keyLabel)
        content.addSubview(licenseKeyField)

        activateButton.target = self
        activateButton.action = #selector(activateLicense)
        activateButton.keyEquivalent = "\r"
        activateButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(activateButton)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        var constraints = [
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),

            emailLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            emailLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 22),
            emailField.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            emailField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            emailField.topAnchor.constraint(equalTo: emailLabel.bottomAnchor, constant: 6),

            keyLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            keyLabel.topAnchor.constraint(equalTo: emailField.bottomAnchor, constant: 16),
            licenseKeyField.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            licenseKeyField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            licenseKeyField.topAnchor.constraint(equalTo: keyLabel.bottomAnchor, constant: 6),

            activateButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            statusLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            statusLabel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ]

        #if PAID_BUILD
        constraints.append(contentsOf: [
            activateButton.topAnchor.constraint(equalTo: licenseKeyField.bottomAnchor, constant: 18),
            statusLabel.topAnchor.constraint(equalTo: activateButton.bottomAnchor, constant: 16)
        ])
        statusLabel.stringValue = "Bitte gib die E-Mail-Adresse und den Lizenzschlüssel aus deiner Kaufbestätigung ein."
        #else
        trialButton.target = self
        trialButton.action = #selector(startTrial)
        trialButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(trialButton)

        purchaseButton.target = self
        purchaseButton.action = #selector(openPurchasePage)
        purchaseButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(purchaseButton)

        constraints.append(contentsOf: [
            activateButton.topAnchor.constraint(equalTo: licenseKeyField.bottomAnchor, constant: 18),
            trialButton.trailingAnchor.constraint(equalTo: activateButton.trailingAnchor),
            trialButton.topAnchor.constraint(equalTo: activateButton.bottomAnchor, constant: 12),
            purchaseButton.trailingAnchor.constraint(equalTo: activateButton.trailingAnchor),
            purchaseButton.topAnchor.constraint(equalTo: trialButton.bottomAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: purchaseButton.bottomAnchor, constant: 12)
        ])
        do {
            if let trial = try LemonSqueezyLicense.savedTrialStatus() {
                if trial.isActive {
                    trialButton.title = "Test fortsetzen (\(trial.remainingDays) Tage)"
                } else if trial.isExpired {
                    trialButton.isEnabled = false
                    trialButton.title = "Testzeitraum abgelaufen"
                    statusLabel.stringValue = "Kaufe eine Lizenz, um Old Launchpad weiter zu nutzen."
                } else {
                    trialButton.title = "30 Tage testen (\(trial.remainingDays) Tage übrig)"
                    statusLabel.stringValue = "Der Zeitraum wird ab dem ersten App-Start berechnet."
                }
            }
        } catch {
            trialButton.isEnabled = false
            statusLabel.stringValue = error.localizedDescription
        }
        #endif

        NSLayoutConstraint.activate(constraints)

        center()
    }

    #if !PAID_BUILD
    @objc private func openPurchasePage() {
        guard NSWorkspace.shared.open(checkoutURL) else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Die Kaufseite konnte nicht geöffnet werden. Bitte versuche es erneut."
            return
        }
    }
    #endif

    @objc private func activateLicense() {
        activateButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Lizenz wird geprüft …"
        let email = emailField.stringValue
        let licenseKey = licenseKeyField.stringValue

        Task { [weak self] in
            do {
                let _ = try await LemonSqueezyLicense.activate(licenseKey: licenseKey, email: email)
                guard let self else { return }
                self.statusLabel.textColor = .systemGreen
                self.statusLabel.stringValue = "Lizenz aktiviert."
                self.onAccessGranted()
            } catch {
                guard let self else { return }
                self.statusLabel.textColor = .systemRed
                self.statusLabel.stringValue = error.localizedDescription
                self.activateButton.isEnabled = true
            }
        }
    }

    #if !PAID_BUILD
    @objc private func startTrial() {
        trialButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Testzeitraum wird vorbereitet …"

        do {
            let trial = try LemonSqueezyLicense.startOrResumeTrial()
            statusLabel.textColor = .systemGreen
            statusLabel.stringValue = "Test aktiv – noch \(trial.remainingDays) Tage."
            onAccessGranted()
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
            trialButton.isEnabled = true
            if case LemonSqueezyLicenseError.trialExpired = error {
                trialButton.isEnabled = false
            }
        }
    }
    #endif
}
