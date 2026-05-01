cask "bubo" do
  version "1.11.25"
  sha256 "285d61c395c22a7067822bf2be9d092c9d7f4709df670e2f9221cea0ef63db90"

  url "https://github.com/avpv/bubo/releases/download/v#{version}/Bubo.dmg"
  name "Bubo"
  desc "Menu bar calendar with full-screen meeting alerts and Pomodoro timer"
  homepage "https://github.com/avpv/bubo"

  depends_on macos: ">= :ventura"

  app "Bubo.app"

  postflight do
    # Only strip com.apple.quarantine. `xattr -cr` would also drop
    # com.apple.macl, the attribute macOS uses to bind TCC permissions
    # (Calendar, Reminders, Accessibility, …) to the signed binary;
    # losing it forces the user to re-grant every permission on each
    # reinstall and leaves the app in a half-broken state on first launch.
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Bubo.app"],
                   must_succeed: false
  end

  zap trash: [
    "~/Library/Preferences/com.avpv.Bubo.plist",
    "~/Library/Application Support/com.avpv.Bubo",
  ]
end
