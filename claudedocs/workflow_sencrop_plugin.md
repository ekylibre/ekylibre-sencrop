# Workflow d'implémentation — Plugin Ekylibre Sencrop

> **Statut** : Plan d'implémentation uniquement. Aucun code n'est exécuté à ce stade.
> **Stratégie** : systematic
> **Profondeur** : deep
> **Source de référence** : plugin `ekylibre-weenat` (modèle architectural)
> **Cible** : adaptation au fournisseur Sencrop (API v1, OAuth2 client credentials)
> **Document généré le** : 2026-05-19
> **Révision v2** : 2026-05-19 — enrichi avec la doc Observable « API workflow for users / partners » de Vincent Guilbaud (Sencrop). Voir § 9 (Annexe).

### Changelog v2

- 🔑 **Authentification** : passage Bearer statique → **OAuth2 client credentials** (`/oauth2/token`).
- 🆔 **`userId`** : récupéré dynamiquement via `GET /me` (n'a plus à être saisi manuellement).
- 📍 **Géolocalisation** : trouvée dans `devicesStatuses[id].contents.{latitude, longitude}`.
- 🩺 **Health-check** : endpoint dédié `GET /ping`.
- 🤝 **Mode partenaire** : flow d'impersonation (`grant_type=module`) et endpoints `/partners/{partnerId}/devices` documentés en annexe.
- ➕ **Mesures supplémentaires** : `TEMPERATURE_MIN`, `TEMPERATURE_MAX`, `WET_TEMPERATURE`, `WIND_DIRECTION`, `LEAF_WETNESS`, `LEAF_SENSOR_CONDUCTIVITY`.
- ⚠️ **Codes dépréciés** : `WIND_MAX`, `WIND_MEAN`, `RH_AIR_H1`, `TEMP_AIR_H1`, `RAIN_TIC` (à éviter).

---

## 1. Vision et objectifs

Construire un plugin Ekylibre `sencrop` qui :

1. S'enregistre comme intégration (`ActionIntegration::Base`) configurable via les paramètres d'authentification Sencrop.
2. Initialise au premier lancement une importation historique (≈ 150 jours) des stations météo Sencrop accessibles à l'utilisateur.
3. Met à jour de façon incrémentale (toutes les heures) les analyses des capteurs en transcodant les mesures Sencrop vers les indicateurs météo natifs d'Ekylibre.
4. Reproduit l'expérience du plugin Weenat existant (i18n, assets, jobs, version, CI, gemspec, Plugfile).

### Différences structurelles à anticiper vs Weenat

| Aspect | Weenat | Sencrop |
|---|---|---|
| Authentification | `POST /api-token-auth/` avec `email`/`password` → JWT | **OAuth2 client credentials** : `POST /oauth2/token` avec `Authorization: Basic base64(appId:appSecret)` + body `{grant_type:"client_credentials", scope:"user"}` → `access_token` + `expires_in` |
| Identité utilisateur | implicite (token = utilisateur) | `GET /me` → `{ item: userId, users: {…}, places: {…} }` |
| Base URL | `https://api-prod.weenat.com/api/v2` | `https://api.sencrop.com/v1` |
| Health-check | `POST /api-token-auth/` (test login) | `GET /ping` |
| Unité de regroupement | `plot` (parcelle) | `device` (capteur) lié à un `userId` (ou un `partnerId` en mode partenaire) |
| Géolocalisation | `plot.latitude` / `plot.longitude` | `devicesStatuses[id].contents.{latitude, longitude}` |
| Format temporel | EPOCH (secondes) | ISO 8601 (`2022-01-28T01:00:00+01:00`) ; `key` de bucket en epoch ms |
| Données retournées | Hash `{ts => {RR, T, U, FF, FXY}}` | Structure normalisée `{item, measures:{interval, data:[{key, MEASURE:{value}}]}}` |
| Période max par appel | 10–35 jours (contrainte) | Paramètre `days` borné côté API ; `beforeDate` glissant |
| Quota | Non spécifié | 100 appels/minute (à respecter) |
| Codes mesures | `RR, T, U, FF, FXY` | `RAIN_FALL, TEMPERATURE, TEMPERATURE_MIN, TEMPERATURE_MAX, RELATIVE_HUMIDITY, WIND_SPEED, WIND_GUST, WIND_DIRECTION, WET_TEMPERATURE, LEAF_WETNESS, LEAF_SENSOR_CONDUCTIVITY` |
| Secret côté frontend | login/password (stocké chiffré) | **Interdit** côté front : `applicationSecret` backend uniquement |
| Renouvellement token | À chaque appel (cf. code Weenat) | Token TTL `expires_in` → cache + refresh à expiration |

---

## 2. Architecture cible (arborescence)

Structure cible reproduisant le squelette Weenat :

```
ekylibre-sencrop/
├── Gemfile
├── Plugfile
├── Rakefile
├── README.md
├── LICENSE (déjà présent)
├── sencrop.gemspec
├── .gitignore
├── .gitlab-ci.yml
├── .rubocop.yml
├── bin/
│   └── rubocop
├── lib/
│   ├── sencrop.rb
│   └── sencrop/
│       ├── engine.rb
│       └── version.rb
├── app/
│   ├── assets/
│   │   └── images/
│   │       └── integrations/
│   │           ├── sencrop.png
│   │           └── sencrop.svg
│   ├── integrations/
│   │   └── sencrop/
│   │       └── sencrop_integration.rb
│   └── jobs/
│       ├── sencrop_first_run_job.rb
│       └── sencrop_fetch_update_create_job.rb
├── config/
│   └── locales/
│       ├── eng.yml
│       ├── fra.yml
│       ├── spa.yml
│       ├── por.yml
│       ├── deu.yml
│       ├── ita.yml
│       ├── cmn.yml
│       ├── jpn.yml
│       └── arb.yml
└── claudedocs/
    └── workflow_sencrop_plugin.md  ← ce document
```

---

## 3. Phases d'implémentation

### Phase 0 — Préparation (Setup)

**Objectif** : préparer le squelette du gem/plugin Rails Engine.

**Tâches** :
1. Confirmer la version cible d'Ekylibre (le Plugfile Weenat cible `>= 4.0.0, < 5.0.0` → réutiliser).
2. Demander à `api@sencrop.com` un couple **`applicationId` / `applicationSecret`** (le `userId` n'est plus nécessaire en amont — on le récupèrera via `GET /me`).
   - ⚠️ Le secret n'est **pas récupérable** après émission : le stocker immédiatement de façon sûre.
   - ⚠️ Le secret doit rester **backend-only** ; ne jamais l'exposer dans des assets JS, ni dans le code public du plugin.
3. Décider du scope : `user` (compte agriculteur unique) ou `module` (impersonation pour un partenaire multi-utilisateurs — cf. § Annexe).
4. Décider du nom canonique : `sencrop` (snake_case partout) ; classe principale `Sencrop`.

**Livrables** : aucun fichier (étape préalable).

**Critères de validation** :
- `applicationId` et `applicationSecret` Sencrop disponibles en `.env` local pour le développement.
- Un appel `curl` manuel à `/oauth2/token` retourne `200 OK` + un `access_token` valide.
- Un appel `GET /me` avec ce token retourne un `item` (userId).

---

### Phase 1 — Squelette du gem (fichiers de base)

**Objectif** : créer la coquille Ruby/Bundler/Plugin.

**Fichiers à créer (ordre suggéré)** :

1. **`lib/sencrop/version.rb`**
   - Module `Sencrop`, constante `VERSION = '0.1.0'.freeze`.
2. **`lib/sencrop.rb`**
   - `require 'sencrop/engine'` ; `module Sencrop; end`.
3. **`lib/sencrop/engine.rb`**
   - Classe `Sencrop::Engine < ::Rails::Engine`.
   - Initializer assets (`*.svg *.png`).
   - Initializer i18n (`config/locales/**/*.yml`).
   - Initializer `:ekylibre_sencrop_integration` :
     - `on_check_success` → `SencropFirstRunJob.perform_later`.
     - `run every: :hour` → vérifie `last_sencrop_import` + `sencrop_import_running`, puis `SencropFetchUpdateCreateJob.perform_now(last_imported_at)`.
4. **`sencrop.gemspec`**
   - Nom `sencrop`, version `Sencrop::VERSION`, mêmes dépendances que Weenat (`dotenv`, `vcr`, `webmock`, `bundler`, `minitest`, `rake`, `rubocop`).
   - `spec.files = Dir.glob(%w[{app,config,db,lib}/**/* LICENSE.md])`.
5. **`Gemfile`** — `source 'https://rubygems.org'` + `gemspec`.
6. **`Plugfile`** — `author`, `name 'sencrop'`, `version '1.0.0'`, `app '>= 4.0.0', '< 5.0.0'`.
7. **`Rakefile`** — `Rake::TestTask` pointant sur `test/sencrop/*_test.rb`.
8. **`.rubocop.yml`** — hériter de la config Ekylibre (`https://gitlab.com/ekylibre/tools/rubocop/-/raw/0.2.0/.rubocop.yml`), `TargetRubyVersion: 2.6`, exclusion `bin/**/*`.
9. **`.gitlab-ci.yml`** — stage `lint`, image `registry.gitlab.com/ekylibre/tools/rubocop/rubocop:0.2.0`.
10. **`.gitignore`** — identique à Weenat (`.bundle/`, `Gemfile.lock`, `test/cassettes/`, `.env`, etc.).
11. **`bin/rubocop`** — script wrapper (copie binaire depuis Weenat).
12. **`README.md`** — remplacer l'existant : description, lien `https://developer.sencrop.com/guide`, comportement (initialisation + import horaire).

**Critères de validation** :
- `bundle install` réussit dans le contexte de l'application Ekylibre hôte.
- `rubocop --parallel` ne signale aucune erreur critique.
- Le moteur Rails est chargé sans exception.

---

### Phase 2 — Intégration Sencrop (couche API)

**Objectif** : implémenter `Sencrop::SencropIntegration < ActionIntegration::Base`.

**Fichier** : `app/integrations/sencrop/sencrop_integration.rb`.

**Constantes** :
```ruby
BASE_URL   = 'https://api.sencrop.com/v1'.freeze
TOKEN_URL  = "#{BASE_URL}/oauth2/token".freeze
PING_URL   = "#{BASE_URL}/ping".freeze
ME_URL     = "#{BASE_URL}/me".freeze
DEVICES_URL      = ->(user_id) { "#{BASE_URL}/users/#{user_id}/devices" }
DEVICE_URL       = ->(user_id, device_id) { "#{BASE_URL}/users/#{user_id}/devices/#{device_id}" }
HOURLY_URL       = ->(user_id, device_id) { "#{BASE_URL}/users/#{user_id}/devices/#{device_id}/data/hourly" }
DAILY_URL        = ->(user_id, device_id) { "#{BASE_URL}/users/#{user_id}/devices/#{device_id}/data/daily" }
STATISTICS_URL   = ->(user_id, device_id) { "#{BASE_URL}/users/#{user_id}/devices/#{device_id}/statistics" }
PARTNER_DEVICES_URL = ->(partner_id) { "#{BASE_URL}/partners/#{partner_id}/devices" }

DEFAULT_MEASURES = %w[
  RAIN_FALL TEMPERATURE TEMPERATURE_MIN TEMPERATURE_MAX
  RELATIVE_HUMIDITY WIND_SPEED WIND_GUST WIND_DIRECTION
].join(',').freeze
```

**Paramètres d'intégration** :
- `parameter :application_id` — identifiant client OAuth2.
- `parameter :application_secret` — secret client OAuth2 (chiffré en base, **jamais loggé**).
- `parameter :scope` (optionnel, défaut `user`) — `user` ou `module` (pour le flow partenaire).
- ❌ **Plus de `user_id` en paramètre** : il est résolu dynamiquement via `GET /me`.

**Authentification** :
```ruby
authenticate_with :check do
  parameter :application_id
  parameter :application_secret
end
```

**Méthodes (`calls :retrieve_token, :fetch_me, :fetch_devices, :fetch_device, :fetch_hourly_data, :fetch_daily_data, :fetch_statistics`)** :

1. **`retrieve_token`** — `POST /oauth2/token` :
   ```ruby
   basic = Base64.strict_encode64("#{app_id}:#{app_secret}")
   headers = { 'Authorization' => "Basic #{basic}", 'Content-Type' => 'application/json' }
   body    = { grant_type: 'client_credentials', scope: 'user' }.to_json
   ```
   Retourne `{ access_token, token_type, expires_in }`.
2. **`fetch_me`** — `GET /me` avec Bearer ; retourne `{ item: userId, users:{…}, places:{…} }`.
3. **`fetch_devices(user_id)`** — `GET /users/{user_id}/devices?includeHistory=false` ; retourne `{ items:[ids], devicesStatuses:{id => {contents:{name, latitude, longitude, …}}}, … }`.
4. **`fetch_device(user_id, device_id)`** — `GET /users/{user_id}/devices/{device_id}` (fallback si latitude/longitude manque dans la liste).
5. **`fetch_hourly_data(user_id, device_id, before_date_iso, days, measures = DEFAULT_MEASURES)`** — `GET …/data/hourly?beforeDate=…&days=…&measures=…`.
6. **`fetch_daily_data(...)`** — analogue, endpoint `/data/daily`.
7. **`fetch_statistics(user_id, device_id, start_date_iso, end_date_iso, measures)`** — endpoint `/statistics`.

**Health-check** :
```ruby
def check(integration = nil)
  integration = fetch integration
  # 1) Token retrieval
  token_response = retrieve_token
  # 2) Ping API
  get_json(PING_URL, 'Authorization' => "Bearer #{token}") do |r|
    r.success { Rails.logger.info 'Sencrop API reachable'.green }
    r.error   { r.error :api_down }
  end
end
```

**Gestion du token (cache + refresh)** :
- Stocker le token et son `expires_at` dans une `Preference` (`sencrop_access_token`, `sencrop_token_expires_at`).
- À chaque appel, si `Time.zone.now >= expires_at - 60.seconds` → `retrieve_token` à nouveau.
- Exposer un helper privé `def with_token; ...; end` qui injecte automatiquement l'en-tête Bearer.

**Gestion d'erreurs** :
- `ServiceError` (cf. Weenat) pour normaliser.
- 401 (token périmé) → invalider le cache et retenter une fois.
- 429 (rate limit) → backoff exponentiel (1 s, 2 s, 4 s, max 3 tentatives).
- Respecter le quota 100 req/min : compteur in-memory ou `sleep(0.65)` entre appels.
- Logger les 4xx/5xx ; ne pas lever d'exception bloquant le job complet.

**Critères de validation** :
- `Sencrop::SencropIntegration.check.execute` retourne succès (token + ping 200).
- `Sencrop::SencropIntegration.fetch_me.execute` retourne un `item` (userId numérique).
- `Sencrop::SencropIntegration.fetch_devices(user_id).execute` retourne la liste avec `devicesStatuses[id].contents.{latitude, longitude}`.

---

### Phase 3 — Job d'initialisation (SencropFirstRunJob)

**Objectif** : importer ≈ 150 jours d'historique sur les devices Sencrop.

**Fichier** : `app/jobs/sencrop_first_run_job.rb`.

**Algorithme** :
1. `Preference.set!('sencrop_import_running', true, 'boolean')`.
2. Définir le transcodage :
   ```ruby
   TRANSCODE = {
     'RAIN_FALL'         => { indicator: :cumulated_rainfall,          unit: :millimeter },
     'TEMPERATURE'       => { indicator: :average_temperature,         unit: :celsius },
     'TEMPERATURE_MIN'   => { indicator: :minimal_temperature,         unit: :celsius },
     'TEMPERATURE_MAX'   => { indicator: :maximal_temperature,         unit: :celsius },
     'RELATIVE_HUMIDITY' => { indicator: :average_relative_humidity,   unit: :percent },
     'WIND_SPEED'        => { indicator: :average_wind_speed,          unit: :kilometer_per_hour },
     'WIND_GUST'         => { indicator: :maximal_wind_speed,          unit: :kilometer_per_hour }
     # WIND_DIRECTION, WET_TEMPERATURE, LEAF_WETNESS, LEAF_SENSOR_CONDUCTIVITY :
     # à mapper uniquement si l'indicateur Ekylibre existe (cf. Nomen::Indicators).
   }.freeze
   ```
3. Résoudre l'utilisateur courant : `user_id = Sencrop::SencropIntegration.fetch_me.execute → response[:item]` (cache mémoire pendant le job).
4. `fetch_devices(user_id)` → itérer sur `items` (ID de devices), résoudre chaque device dans `devicesStatuses[id]`.
5. Pour chaque device :
   - `contents = devicesStatuses[id][:contents]`.
   - `lat = contents[:latitude]`, `lon = contents[:longitude]`.
   - Si absent → fallback `fetch_device(user_id, device_id)` pour récupérer le détail.
   - `geolocation = ::Charta.new_point(lat, lon).to_ewkt`.
   - `Sensor.find_or_create_by(vendor_euid: :sencrop, euid: device_id, retrieval_mode: :integration)`.
   - Update : `name: contents[:name]`, `model_euid: :sencrop`, `partner_url: 'https://app.sencrop.com'`, `last_transmission_at: Time.zone.now`.
6. Découper l'historique en fenêtres de `days` (ex. 15 j × 10) ; `before_date_iso = (Time.now.utc - i × 15.days).iso8601`.
7. Pour chaque fenêtre, `fetch_hourly_data(user_id, device_id, before_date_iso, 15, DEFAULT_MEASURES)`.
8. Parcourir `response[:measures][:data]` ; pour chaque point :
   - `key_ms = point[:key]` (epoch ms).
   - `read_at = Time.at(key_ms / 1000.0).utc`.
   - `reference_number = "#{sensor.euid}_#{key_ms}"`.
   - `Sensor#analyses.find_or_initialize_by(reference_number:, sampled_at: read_at, analysed_at: read_at, retrieval_status: :ok, nature: :sensor_analysis, sampling_temporal_mode: :period)`.
   - Si nouveau : `analyse.geolocation = geolocation; analyse.save!`.
   - Pour chaque mesure transcodée : `value = point[code][:value]`. Si non nul → `analyse.read!(transcode[:indicator], value.in(transcode[:unit]))`.
9. Collecter le `key_ms` maximum (converti en epoch s) → `Preference.set!('last_sencrop_import', max_epoch_s, 'integer')`.
10. `Preference.set!('sencrop_import_running', false, 'boolean')`.

**Critères de validation** :
- Après exécution, un `Sensor` existe par device et possède des `analyses` horaires couvrant 150 jours.
- Aucune duplication (`find_or_initialize_by` sur `reference_number`).

---

### Phase 4 — Job incrémental (SencropFetchUpdateCreateJob)

**Objectif** : récupérer toutes les analyses depuis le dernier import.

**Fichier** : `app/jobs/sencrop_fetch_update_create_job.rb`.

**Algorithme** :
1. `Preference.set!('sencrop_import_running', true, 'boolean')`.
2. Reprendre la logique de découpage Weenat mais en jours ISO :
   - `period_length_days = 7` (ou 15).
   - Nombre de fenêtres = `((now - last_imported_at) / period_length).ceil`.
3. Pour chaque device (même logique de création/mise à jour `Sensor`) :
   - Itérer fenêtres dans l'ordre chronologique inverse (cohérence Weenat).
   - `fetch_hourly_data` puis création des `analyses` (réutiliser le helper du job d'init si extrait).
4. Mettre à jour `last_sencrop_import` au max des `read_at`.
5. `Preference.set!('sencrop_import_running', false, 'boolean')`.

**Refactor recommandé** : extraire dans `lib/sencrop/importer.rb` (ou un concern) la logique partagée entre les deux jobs (`process_device(...)`, `apply_measures(...)`). Si la duplication reste raisonnable (~50 lignes), copier comme Weenat ; sinon mutualiser.

**Critères de validation** :
- Le job ne refait pas l'import complet à chaque tick horaire.
- Idempotent : relancé deux fois de suite, il ne crée pas de doublons.

---

### Phase 5 — Internationalisation et assets

**Objectif** : couvrir toutes les langues du plugin Weenat (eng, fra, spa, por, deu, ita, cmn, jpn, arb) + assets visuels.

**Tâches** :
1. Pour chacune des 9 locales, créer `config/locales/<locale>.yml` avec :
   ```yaml
   <locale>:
     labels:
       sencrop_short_description: ...
       sencrop_long_description: ...
       sencrop_url: https://www.sencrop.com
   ```
   - **FR** : « Capteurs météo connectés à la parcelle » / « Sencrop fournit des stations météo agricoles connectées (pluie, température, hygrométrie, vent) ».
   - **EN** : "Connected weather sensors for parcels" / "Sencrop provides connected agricultural weather stations (rain, temperature, humidity, wind)".
   - Traduire les autres langues sur la même base.
2. Ajouter les assets (à fournir par le designer ou récupérer depuis la presskit Sencrop) :
   - `app/assets/images/integrations/sencrop.png`
   - `app/assets/images/integrations/sencrop.svg`

**Critères de validation** :
- Les labels apparaissent dans l'UI Ekylibre lors de la configuration de l'intégration.
- Le logo Sencrop s'affiche correctement (tailles similaires à Weenat).

---

### Phase 6 — Tests

**Objectif** : valider l'intégration avec VCR/WebMock.

**Tâches** :
1. Installer `test/test_helper.rb` (Minitest + VCR + WebMock).
2. `test/sencrop/sencrop_integration_test.rb` :
   - Cassette pour `fetch_devices` (200 OK avec payload normalisé).
   - Cassette pour `fetch_hourly_data` (deux fenêtres successives).
   - Cas d'erreur : 401 (token invalide), 429 (rate limit), 5xx.
3. `test/sencrop/jobs/sencrop_first_run_job_test.rb` — vérifier création des Sensor, analyses et items via stubs.
4. `test/sencrop/jobs/sencrop_fetch_update_create_job_test.rb` — vérifier l'idempotence et la non-régression.
5. Configurer la CI GitLab (rubocop existe déjà) → ajouter stage `test` exécutant `bundle exec rake`.

**Critères de validation** :
- `bundle exec rake` vert en local et en CI.
- Couverture : intégration API + jobs + transcodage.

---

## 4. Carte de dépendances

```
Phase 0 (token+userId)
    └── Phase 1 (squelette)
            ├── Phase 2 (intégration) ──┐
            │                           ├── Phase 6 (tests, en parallèle dès que P2 stable)
            ├── Phase 3 (first_run_job) ┘
            ├── Phase 4 (fetch_update_job) — dépend de P3 (helpers partagés)
            └── Phase 5 (i18n + assets) — parallélisable dès P1
```

**Parallélisable** : Phase 5 (locales + assets) avec Phase 2/3/4.
**Bloquant** : Phase 0 (sans token, impossible de tester) ; Phase 2 (toute la chaîne dépend du contrat API).

---

## 5. Points ouverts à clarifier avant ou pendant l'implémentation

### Résolus par la doc Observable (v2)

- ✅ **Obtention du `userId`** : `GET /me` → `response[:item]`.
- ✅ **Géolocalisation des devices** : `devicesStatuses[id].contents.{latitude, longitude}`.
- ✅ **Storage du secret** : `Integration#parameters['application_id']` + `application_secret` (jamais en clair côté front).
- ✅ **Format de la clé temporelle** : `key` en epoch **millisecondes** (cohérent avec l'exemple `1507186800000`).

### Encore ouverts

1. **Granularité initiale** : `hourly` (cohérent avec Weenat) ou `daily` pour réduire la volumétrie ? → privilégier `hourly`, fallback `daily` si volumétrie trop élevée.
2. **Valeur `days` maximale autorisée** par appel hourly : à confirmer (la doc évoque « limited values » sans plafond explicite). Hypothèse de travail : 30 jours.
3. **Mesures additionnelles** à exposer : `WIND_DIRECTION`, `WET_TEMPERATURE`, `LEAF_WETNESS`, `LEAF_SENSOR_CONDUCTIVITY`. → arbitrer avec le métier en consultant `Nomen::Indicators` (Ekylibre).
4. **Stratégie de rate limit** : `sleep(0.65)` entre appels ou backoff sur 429 ? → privilégier la détection 429 + retry exponentiel (backoff 1 s/2 s/4 s).
5. **`includeHistory`** : faut-il l'activer pour récupérer les anciens devices remplacés ? → par défaut `false` ; à activer si l'utilisateur signale des trous historiques.
6. **Mode partenaire vs utilisateur** : selon l'accord commercial Ekylibre/Sencrop, choisir `scope=user` (Plug-in pour un seul client) ou `scope=module` + endpoint `/partners/{partnerId}/devices` (cf. Annexe).
7. **TTL exact de `expires_in`** : à mesurer en environnement réel pour calibrer la marge de refresh (la valeur n'est pas figée dans la doc).
8. **Renouvellement du `applicationSecret`** : procédure documentée ? Anticiper la rotation (pas mentionné dans la doc).

---

## 6. Checkpoints de validation

| # | Phase | Checkpoint | Méthode de validation |
|---|---|---|---|
| C1 | P1 | Le plugin charge dans l'app Ekylibre | `bundle exec rails runner 'puts Sencrop::VERSION'` |
| C2a | P2 | `retrieve_token` renvoie `access_token` | Console : payload OAuth2 200 OK |
| C2b | P2 | `fetch_me` renvoie un `item` (userId) | Console : `…fetch_me.execute → response[:item]` |
| C2c | P2 | `check` retourne succès (ping 200) | UI d'intégration : statut « connecté » |
| C3 | P2 | `fetch_devices(user_id)` retourne la liste | Console : présence de `devicesStatuses[id][:contents][:latitude]` |
| C4 | P3 | Job d'init crée Sensors + Analyses | Query SQL `SELECT COUNT(*) FROM sensors WHERE vendor_euid='sencrop'` |
| C5 | P3 | Indicateurs présents (`cumulated_rainfall`, `average_temperature`, `minimal_temperature`, `maximal_temperature`, …) | UI fiche capteur Ekylibre |
| C6 | P4 | Import horaire idempotent | Lancer 2 fois → 0 doublon |
| C7 | P2 | Refresh de token automatique | Forcer `expires_at` dans le passé → un appel suivant déclenche `retrieve_token` |
| C8 | P5 | UI traduite et logo visible | Capture d'écran intégration |
| C9 | P6 | CI verte | Pipeline GitLab |

---

## 7. Risques et atténuations

| Risque | Impact | Atténuation |
|---|---|---|
| `applicationSecret` perdu (irrécupérable) | Re-onboarding complet | Stockage chiffré (`Integration#parameters` + `encrypts`) ; sauvegarde scellée hors-ligne |
| `applicationSecret` fuité (logs, repo) | Compromission API | Filtrer logs Rails (`filter_parameters << :application_secret`) ; jamais en `Rails.logger.info`/`.debug` |
| Expiration du token au milieu d'un import long | Échec brutal | Vérifier `expires_at` avant chaque appel ; retry 401 → refresh + 1 retry |
| Format réel divergeant de la doc | Refonte du transcodage | Itération courte sur P2 avec données live avant d'écrire P3/P4 ; cassettes VCR de référence |
| Volumétrie 150 j × N devices × 24 h | Saturation BDD | Lots + transactions ; surveiller `analyses.items` ; option `daily` |
| Rate limit 100/min dépassé | Échecs partiels | Throttle dans l'intégration ; retry sur 429 (backoff exponentiel) |
| Indicateurs Ekylibre incomplets | Mesures perdues | Lister les indicateurs disponibles côté Ekylibre avant P3 (`Nomen::Indicators`) ; ignorer silencieusement les codes non mappés mais logger |
| Différence locale serveur / UTC | Décalage horaire | Toujours raisonner en UTC ; convertir au moment de l'affichage |
| Mauvais `scope` choisi (`user` vs `module`) | Pas d'accès aux devices d'autres comptes | Cf. § 9 (Annexe) : décider en amont selon le modèle commercial |

---

## 8. Prochaine étape

Lorsque ce plan est validé :

1. Lancer `/sc:implement` (ou exécuter manuellement phase par phase).
2. Commencer par la **Phase 1** (squelette), puis **Phase 2** (intégration) en parallèle avec une cassette VCR de référence.
3. Itérer sur les **Phases 3-4** avec un device de test pour valider de bout en bout avant traduction (Phase 5) et tests (Phase 6).

> Ce document est volontairement figé : il ne sera pas mis à jour en cours d'implémentation. Les ajustements de scope seront reflétés dans des commits + le README final du plugin.

---

## 9. Annexe — Référence API Sencrop (issue Observable)

> Source : [API workflow for users](https://observablehq.com/d/0e7ae541ed09439e?collection=@57ac0233e9966902/sencrop-api-documentation) et [API Workflow for partners](https://observablehq.com/@57ac0233e9966902/api-workflow-for-partners?collection=@57ac0233e9966902/sencrop-api-documentation) (Vincent Guilbaud, Sencrop, 2024).

### 9.1 Authentification OAuth2

**Endpoint** : `POST https://api.sencrop.com/v1/oauth2/token`

#### Flow « client_credentials » (scope `user`)
À utiliser quand l'application accède à **un seul compte utilisateur** (cas Plug-in Ekylibre par client).

```http
POST /v1/oauth2/token HTTP/1.1
Host: api.sencrop.com
Authorization: Basic <base64("applicationId:applicationSecret")>
Content-Type: application/json

{"grant_type": "client_credentials", "scope": "user"}
```

#### Flow « module » (impersonation partenaire)
À utiliser pour accéder aux données d'**utilisateurs ayant activé le module partenaire** Ekylibre côté Sencrop.

```http
POST /v1/oauth2/token HTTP/1.1
Authorization: Basic <base64("applicationId:applicationSecret")>
Content-Type: application/json

{"grant_type": "module", "email": "agriculteur@example.com"}
```

#### Réponse (commune)
```json
{
  "access_token": "eyJhbGciOi...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "scope": "user"
}
```

> ⚠️ Les `access_token` ont une durée de vie limitée (cf. `expires_in`). À cacher localement et **refresh à expiration**.

---

### 9.2 Endpoints clés

| Méthode | Chemin | Description |
|---|---|---|
| `GET` | `/v1/ping` | Health-check (renvoie 200 si l'API est joignable) |
| `GET` | `/v1/me` | Identité de l'utilisateur authentifié |
| `GET` | `/v1/users/{userId}/devices` | Liste des devices de l'utilisateur |
| `GET` | `/v1/users/{userId}/devices/{deviceId}` | Détail d'un device |
| `GET` | `/v1/users/{userId}/devices/{deviceId}/data/raw` | Mesures brutes |
| `GET` | `/v1/users/{userId}/devices/{deviceId}/data/hourly` | Agrégat horaire |
| `GET` | `/v1/users/{userId}/devices/{deviceId}/data/daily` | Agrégat journalier |
| `GET` | `/v1/users/{userId}/devices/{deviceId}/statistics` | Statistiques échelle adaptative |
| `GET` | `/v1/users/{userId}/data/hourly` | Données géolocalisées (sans device) |
| `GET` | `/v1/users/{userId}/statistics` | Statistiques géolocalisées |
| `GET` | `/v1/organisations/{orgId}/devices` | Devices d'une organisation |
| `GET` | `/v1/partners/{partnerId}/devices` | Devices d'un partenaire (pagination `limit`, `start`) |

---

### 9.3 Structures de réponse

#### `GET /me`
```json
{
  "item": 1664,
  "users": {
    "1664": {
      "organisationsIds": [42, 57]
    }
  },
  "places": {
    "place_1": {
      "contents": { "latitude": 48.85, "longitude": 2.35 }
    }
  }
}
```
→ `userId` = `response.item`.

#### `GET /users/{userId}/devices`
```json
{
  "items": [33, 114711],
  "devicesStatuses": {
    "33": {
      "id": "33",
      "identification": "SC999999",
      "contents": {
        "name": "Rain sensor 1",
        "latitude": 47.218,
        "longitude": -1.553
      }
    }
  },
  "models": { ... }
}
```
→ Itérer sur `items` puis lire `devicesStatuses[id].contents`.

#### `GET …/data/hourly`
```json
{
  "item": 33,
  "measures": {
    "interval": "1h",
    "data": [
      {
        "key": 1507186800000,
        "WIND_SPEED":     { "value": 15.5 },
        "WIND_DIRECTION": { "value": 262 },
        "TEMPERATURE":    { "value": 18.2 },
        "RAIN_FALL":      { "value": 0.4 },
        "docCount": 4
      }
    ]
  }
}
```
→ `key` est un **timestamp epoch en millisecondes**. `read_at = Time.at(key / 1000.0).utc`.

#### `GET …/data/daily`
Identique structurellement à `hourly` avec `interval: "1d"`.

#### `GET …/statistics`
```
?startDate=2017-01-01T00:00:00.000Z&endDate=2017-02-01T00:00:00.000Z&measures=…&patched=false
```
Renvoie un agrégat à intervalle adaptatif. `patched=false` exclut les valeurs interpolées.

---

### 9.4 Mesures disponibles

| Code | Unité | Notes |
|---|---|---|
| `RAIN_FALL` | mm | Cumul de pluie sur la période |
| `TEMPERATURE` | °C | Température moyenne |
| `TEMPERATURE_MIN` | °C | Température minimale (hourly/daily) |
| `TEMPERATURE_MAX` | °C | Température maximale (hourly/daily) |
| `RELATIVE_HUMIDITY` | % | Hygrométrie relative |
| `WIND_SPEED` | km/h | Vitesse moyenne |
| `WIND_GUST` | km/h | Rafale maximale |
| `WIND_DIRECTION` | ° (0-360) | Direction |
| `WET_TEMPERATURE` | °C | Température humide (bulb) |
| `LEAF_WETNESS` | minutes | Temps d'humectation foliaire |
| `LEAF_SENSOR_CONDUCTIVITY` | mV | Conductivité capteur foliaire |

**Codes dépréciés (à éviter)** : `WIND_MAX`, `WIND_MEAN`, `RH_AIR_H1`, `TEMP_AIR_H1`, `RAIN_TIC`.

---

### 9.5 Paramètres de requête fréquents

| Paramètre | Type | Endpoints | Description |
|---|---|---|---|
| `beforeDate` | ISO 8601 | hourly, daily, raw | Date butoir supérieure (exclusive) |
| `days` | int | hourly, daily | Nombre de jours à remonter |
| `measures` | csv | hourly, daily, statistics | Liste de codes (cf. § 9.4) |
| `startDate`, `endDate` | ISO 8601 | statistics | Intervalle |
| `patched` | bool | statistics | `false` → données capteur uniquement |
| `includeHistory` | bool | devices | Inclure les devices remplacés |
| `limit` | int (10/50/100) | partners/devices | Pagination |
| `start` | int | partners/devices | Offset de pagination |
| `interval` | enum | statistics | `15m`, `30m`, `hour`, `day`, `week`, `month`, `year` |
| `size` | int | raw | Nombre max de points |

---

### 9.6 Limites et bonnes pratiques

- **Rate limit** : 100 appels/minute (alpha, possible augmentation sur demande).
- **Time buckets** : alignés sur la timezone (la `key` pointe le début du bucket).
- **Format date** : toujours ISO 8601 ; UTC recommandé (`…Z`).
- **Secret** : à conserver **côté backend uniquement** ; non récupérable après émission.
- **Sécurité** : exclure `applicationSecret` et `access_token` des logs Rails (`Rails.application.config.filter_parameters`).

---

### 9.7 Schéma de séquence (cas nominal)

```
[Job Ekylibre]
   │
   │ 1) retrieve_token (si cache expiré)
   ├─────────► POST /v1/oauth2/token
   │  ◄─────── { access_token, expires_in }
   │
   │ 2) fetch_me
   ├─────────► GET /v1/me (Bearer)
   │  ◄─────── { item: userId, … }
   │
   │ 3) fetch_devices(userId)
   ├─────────► GET /v1/users/{userId}/devices
   │  ◄─────── { items, devicesStatuses, … }
   │
   │ 4) Pour chaque device, par fenêtres de N jours :
   │    fetch_hourly_data(userId, deviceId, beforeDate, days, measures)
   ├─────────► GET /v1/users/{u}/devices/{d}/data/hourly?…
   │  ◄─────── { item, measures: { data: [{ key, MEASURE:{value} }, …] } }
   │
   │ 5) Transcodage + create_analyses + Sensor.update
   │
   └─► Preference.set!('last_sencrop_import', max_key_s)
```
