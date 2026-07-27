class Nibble < Formula
  desc "Lightweight, zero-dependency Logitech mouse control for macOS"
  homepage "https://github.com/ben0128/nibble"
  url "https://github.com/ben0128/nibble/archive/refs/tags/v1.8.0.tar.gz"
  sha256 "899a415116dd13785898c6f88ae7facd8c1141e7d2d67be7c8cc155b1bab6825"
  license "MIT"
  head "https://github.com/ben0128/nibble.git", branch: "main"

  # builds with the Command Line Tools' swiftc — full Xcode not required
  depends_on :macos

  def install
    system "make"
    bin.install "nibble"
  end

  def caveats
    <<~EOS
      Grant Input Monitoring to your terminal before first run:
        System Settings > Privacy & Security > Input Monitoring

      Button remapping additionally needs Accessibility permission and
      the resident menu bar (`nibble menubar`).

      This formula installs the CLI only. For the menu bar app bundle —
      low-battery notifications and "start at login" — use the cask instead:
        HOMEBREW_CASK_OPTS=--no-quarantine brew install --cask ben0128/nibble/nibble
    EOS
  end

  test do
    assert_match "nibble", shell_output("#{bin}/nibble version")
  end
end
