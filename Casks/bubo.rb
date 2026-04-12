cask "bubo" do
  version "1.10.21"
  sha256 "fceb04166568c5917342b616257619c4703d02fe83144430d32b47b6521e6445"

  url "https://github.com/avpv/bubo/releases/download/v#{version}/Bubo.dmg"
  name "Bubo"
  desc "Menu bar calendar with full-screen meeting alerts and Pomodoro timer"
  homepage "https://github.com/avpv/bubo"

  depends_on macos: ">= :ventura"

  app "Bubo.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/Bubo.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.avpv.Bubo.plist",
    "~/Library/Application Support/com.avpv.Bubo",
  ]
end
