cask "bubo" do
  version "1.11.29"
  sha256 "d9180e882c4d1c4f4a59cab52a715dc509455f3ade11ffa45fbc7eed1c77edf7"

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
