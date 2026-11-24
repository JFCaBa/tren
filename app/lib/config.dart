/// Timetables (index.json, feeds/): built nightly on our server; GitHub Pages is the fallback.
const dataUrl = 'https://api.whatplatform.uk/anden/data';
const pagesUrl = 'https://jfcaba.github.io/tren';
const privacyUrl = '$pagesUrl/privacidad.html'; // linked from the stores: stays on Pages
const rtUrl = 'https://gtfsrt.renfe.com/trip_updates.json';
const positionsUrl = 'https://gtfsrt.renfe.com/vehicle_positions.json';
const alertsUrl = 'https://gtfsrt.renfe.com/alerts.json';

/// Our follow server (iPhone push, and one train's live reading). Overridable for tests.
const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'https://api.whatplatform.uk/anden');
const userAgent = 'Anden/1.4';
