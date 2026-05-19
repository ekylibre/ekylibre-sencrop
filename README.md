# Sencrop

Plugin to integrate Sencrop connected weather stations into Ekylibre analyses.

Based on Sencrop API v1 (OAuth2 client credentials).

- API documentation: https://developer.sencrop.com/guide
- Sencrop App: https://app.sencrop.com

## Behavior

1. **First run** (after integration check succeeds): imports ~150 days of historical hourly data per device.
2. **Hourly job**: incrementally pulls new hourly data since the last successful import.

## Configuration

The integration requires the following parameters (request them from `api@sencrop.com`):

- `application_id`: OAuth2 application identifier.
- `application_secret`: OAuth2 application secret (stored backend-side only; **never** exposed in frontend assets or logs).

The user `userId` is resolved automatically via `GET /me` (no manual configuration needed).

## Indicators mapping

| Sencrop code | Ekylibre indicator | Unit |
|---|---|---|
| `RAIN_FALL` | `cumulated_rainfall` | `millimeter` |
| `TEMPERATURE` | `average_temperature` | `celsius` |
| `TEMPERATURE_MIN` | `minimal_temperature` | `celsius` |
| `TEMPERATURE_MAX` | `maximal_temperature` | `celsius` |
| `RELATIVE_HUMIDITY` | `average_relative_humidity` | `percent` |
| `WIND_SPEED` | `average_wind_speed` | `kilometer_per_hour` |
| `WIND_GUST` | `maximal_wind_speed` | `kilometer_per_hour` |

Codes returned by the API but not mapped (e.g. `WIND_DIRECTION`, `WET_TEMPERATURE`, `LEAF_WETNESS`, `LEAF_SENSOR_CONDUCTIVITY`) are silently ignored.

## Missing assets

The integration ships without the Sencrop logo. Add the following before publishing:

- `app/assets/images/integrations/sencrop.png`
- `app/assets/images/integrations/sencrop.svg`

## Implementation plan

See `claudedocs/workflow_sencrop_plugin.md` for the full implementation workflow used to build this plugin.
