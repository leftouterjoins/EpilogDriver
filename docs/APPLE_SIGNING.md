# Apple Code Signing & Notarization

This document explains how to enable Apple Developer ID signing for the Epilog Driver installer package.

## Overview

When enabled, the release workflow will:
1. Sign the `rastertoepiloz` binary with Developer ID Application certificate
2. Sign the installer package with Developer ID Installer certificate
3. Submit the package to Apple for notarization
4. Staple the notarization ticket to the package

This eliminates Gatekeeper warnings when users install the driver.

## Code Changes

### `Installer/build-pkg.sh`
- Added `--sign` flag to enable code signing mode
- Signs binary with hardened runtime (`codesign --options runtime`)
- Signs component package (`pkgbuild --sign`)
- Signs final product archive (`productsign`)

### `.github/workflows/release.yml`
- Imports certificates from GitHub secrets into a temporary keychain
- Conditionally signs based on whether `APPLE_CERTIFICATE_P12` secret exists
- Submits to Apple notarization service (`xcrun notarytool`)
- Staples notarization ticket (`xcrun stapler`)
- Cleans up temporary keychain after job completes

## Current Behavior

- **Without secrets configured**: Releases build unsigned packages (works as before)
- **With secrets configured**: Releases are automatically signed and notarized

## Setup Instructions

### Step 1: Create Certificates

1. Log in to https://developer.apple.com/account
2. Go to **Certificates, Identifiers & Profiles**
3. Click **+** to create a new certificate
4. Select **Developer ID Application** → Continue
5. Upload a Certificate Signing Request (CSR):
   - Open Keychain Access
   - Certificate Assistant → Request a Certificate from a Certificate Authority
   - Save to disk
6. Download the certificate and double-click to install
7. Repeat steps 3-6 for **Developer ID Installer** certificate

### Step 2: Export Certificates

1. Open **Keychain Access**
2. Find your "Developer ID Application" certificate
3. Right-click → Export → Save as `.p12` with a strong password
4. Repeat for "Developer ID Installer" certificate
5. Combine and encode for GitHub:

```bash
# Combine certificates (if exported separately)
cat "Developer ID Application.p12" "Developer ID Installer.p12" > combined.p12

# Or export both at once by selecting both in Keychain Access

# Base64 encode for GitHub
base64 -i combined.p12 | pbcopy
# The encoded string is now in your clipboard
```

### Step 3: Create App-Specific Password

1. Go to https://appleid.apple.com/account/manage
2. Sign in with your Apple ID
3. Navigate to **App-Specific Passwords**
4. Click **Generate**
5. Name it "EpilogDriver Notarization"
6. Save the generated password securely

### Step 4: Add GitHub Secrets

Go to your repository: **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

Add these secrets:

| Secret Name | Value |
|-------------|-------|
| `APPLE_CERTIFICATE_P12` | Base64-encoded .p12 file from Step 2 |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when exporting .p12 |
| `APPLE_ID` | Your Apple ID email address |
| `APPLE_TEAM_ID` | Your Team ID (found at developer.apple.com) |
| `APPLE_APP_PASSWORD` | App-specific password from Step 3 |

### Step 5: Merge and Test

```bash
# Merge the signing branch into master
git checkout master
git merge feature/apple-signing
git push origin master

# Create a test release
git tag v1.3.0-beta
git push origin v1.3.0-beta
```

Monitor the GitHub Actions workflow to verify signing and notarization succeed.

## Troubleshooting

### "No identity found"
- Ensure both Developer ID Application and Installer certificates are in the .p12
- Verify the .p12 password is correct in `APPLE_CERTIFICATE_PASSWORD`

### Notarization fails
- Check that `APPLE_ID` and `APPLE_APP_PASSWORD` are correct
- Ensure the Apple ID has accepted the latest developer agreements
- Verify `APPLE_TEAM_ID` matches your developer account

### "The signature is invalid"
- Make sure hardened runtime is enabled (`--options runtime`)
- Verify the binary doesn't use any disallowed entitlements

## Local Signing (Optional)

You can also sign locally for testing:

```bash
# Build signed package locally
./Installer/build-pkg.sh --sign

# The script will use certificates from your login keychain
```

## References

- [Apple Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS Software](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [Creating Developer ID Certificates](https://developer.apple.com/help/account/create-certificates/create-developer-id-certificates)
