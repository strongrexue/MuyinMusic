Pod::Spec.new do |s|
  s.name             = 'audio_service'
  s.version          = '0.0.1'
  s.summary          = 'iOS stub for the forked audio_service plugin.'
  s.description      = <<-DESC
Placeholder iOS registration so the app compiles; the AVAudioSession /
MPNowPlayingInfoCenter backed service lands in a later iOS-branch commit.
                       DESC
  s.homepage         = 'https://github.com/strongrexue/MuyinMusic'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Muyin' => 'strongrexue@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
