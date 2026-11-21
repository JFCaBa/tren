const baseUrl = 'https://jfcaba.github.io/tren';
const privacyUrl = '$baseUrl/privacidad.html';
const rtUrl = 'https://gtfsrt.renfe.com/trip_updates.json';
const positionsUrl = 'https://gtfsrt.renfe.com/vehicle_positions.json';

/// Our follow server (iPhone push, and one train's live reading). Overridable for tests.
const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'https://api.whatplatform.uk/anden');
const userAgent = 'Anden/1.3';
