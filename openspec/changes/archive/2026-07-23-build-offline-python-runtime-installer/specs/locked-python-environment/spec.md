## ADDED Requirements

### Requirement: Declared dependency set
The environment SHALL include pandas, mysql-connector-python, faker, selenium, beautifulsoup4, webdriver-manager, flask, paho-mqtt, networkx, matplotlib, openpyxl, numpy, scikit-learn, and seaborn as its declared direct dependencies.

#### Scenario: Direct requirements are complete
- **WHEN** the dependency input is checked
- **THEN** every required direct package is present exactly once and no user-supplied package source is merged into it

### Requirement: Fully locked dependency graph
The build SHALL resolve the direct requirements into a committed `requirements.txt` that pins every direct and transitive dependency to an exact version and accepted SHA-256 hashes for CPython 3.13.14 on Windows x64.

#### Scenario: Stable compatible versions are selected
- **WHEN** the initial lock or an approved refresh is generated
- **THEN** it selects stable non-prerelease releases that provide compatible Windows x64 wheels and records the complete resolved graph with hashes

#### Scenario: Source-only dependency is rejected
- **WHEN** a selected package lacks a compatible binary wheel
- **THEN** lock or build validation fails rather than compiling source on the target computer

### Requirement: Immutable offline payload
The target installer SHALL install Python dependencies only from its bundled wheelhouse and SHALL neither contact a package index nor read external requirements or additional package arguments.

#### Scenario: Offline dependency installation
- **WHEN** a user installs on a computer with no network connectivity
- **THEN** all locked dependencies install from the bundled wheelhouse successfully

#### Scenario: External requirements are ignored
- **WHEN** a `requirements.txt` or other package file is placed beside the executable
- **THEN** the installer does not read or install from it

#### Scenario: Missing wheel fails closed
- **WHEN** a required locked wheel is absent from the payload
- **THEN** installation fails without falling back to PyPI or a domestic mirror

### Requirement: Payload integrity verification
The installer SHALL verify the configured Python runtime artifact and every wheel against the release manifest before executing or installing them.

#### Scenario: Valid payload proceeds
- **WHEN** all calculated SHA-256 values match the build manifest
- **THEN** runtime and dependency installation may proceed

#### Scenario: Tampered payload is rejected
- **WHEN** any payload hash differs from the manifest
- **THEN** installation stops, records the mismatched artifact, and does not activate the staged environment

### Requirement: Installed environment manifest
The installer SHALL write a machine-readable manifest containing installer version, Python version and ownership, executable path, dependency versions, artifact hashes, build commit, and verification result.

#### Scenario: Successful manifest publication
- **WHEN** all verification succeeds
- **THEN** the manifest is stored in the managed installation and matches the active interpreter and installed package metadata

### Requirement: Functional post-install verification
Before activation, the installer SHALL validate the interpreter architecture and path, run `pip check`, compare installed versions with the lock, import every declared dependency, and execute representative offline functional smoke tests.

#### Scenario: Scientific and file-processing smoke tests
- **WHEN** post-install verification runs
- **THEN** NumPy and Pandas calculations, an OpenPyXL workbook round trip, a headless Matplotlib render, and a small scikit-learn training operation succeed

#### Scenario: Service and utility smoke tests
- **WHEN** post-install verification runs
- **THEN** Flask test-client, NetworkX, Faker, BeautifulSoup, MySQL connector, Paho MQTT client construction, Selenium import, and webdriver-manager import checks succeed without external service connections

#### Scenario: Dependency inconsistency fails installation
- **WHEN** `pip check`, version comparison, import, or any required smoke test fails
- **THEN** verification returns a nonzero result and the staged environment is not activated

### Requirement: Selenium offline boundary
The environment SHALL install Selenium and webdriver-manager offline but SHALL NOT bundle or download a browser or WebDriver during installation or verification.

#### Scenario: Selenium verification remains offline
- **WHEN** post-install verification reaches Selenium checks
- **THEN** it validates package import and metadata without launching a browser or contacting a driver service

#### Scenario: Runtime driver dependency is documented
- **WHEN** a user consults the usage documentation
- **THEN** it states that first real browser automation may require a compatible browser, driver, and network access unless the organization separately manages fixed browser artifacts

