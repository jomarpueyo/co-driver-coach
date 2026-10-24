-- Co-Driver Coach: keep the extensions loaded across level and scenario changes.
setExtensionUnloadMode('coDriverCoach', 'manual')
extensions.load('coDriverCoach')
setExtensionUnloadMode('coDriverAnalysis', 'manual')
extensions.load('coDriverAnalysis')
setExtensionUnloadMode('coDriverEngineer', 'manual')
extensions.load('coDriverEngineer')
setExtensionUnloadMode('coDriverLaps', 'manual')
extensions.load('coDriverLaps')
