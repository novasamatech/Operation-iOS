Pod::Spec.new do |s|
  s.name             = 'Operation-iOS'
  s.version          = '2.1.0'
  s.summary          = 'Takes data from "rich" remote source and caches them in originaly "poor" local storage to speed up user interface.'

  s.description      = 'Library is aimed to solve a problem of providing persistent (cached) data while fresh one is being fetched from data source. Currently there are 3 types of data providers. DataProvider implementation is aimed to manage identifiable list of entities while SingleValueProvider deals with single objects. Finally, StreamableDataProvider is designed work with streamable data sources, for example, web sockets. Clients can subsribe for changes in data provider to update interface as soon as fresh data is fetched from the source. Currently, there is a single implementation of local storage based on Core Data. Interaction with the library occurs via native Operation concept to simplify chaining and dependency management.'

  s.homepage         = 'https://github.com/novasamatech/Operation-iOS'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Ruslan Rezin' => 'ruslan@novawallet.io' }
  s.source           = { :git => 'https://github.com/novasamatech/Operation-iOS.git', :tag => s.version.to_s }

  s.ios.deployment_target = '14.0'

  s.source_files = 'Operation-iOS/Classes/**/*'
  s.swift_version = '5.0'

  s.test_spec do |ts|
    ts.source_files = 'Tests/**/*.swift'
    ts.dependency 'FireMock'
    ts.resources = ['Tests/**/*.xcdatamodeld', 'Tests/**/*.json']
  end
  
end
