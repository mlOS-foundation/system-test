# E2E Implementation Plan: Install → Publish → Inference

## Goal

Materialize a production-grade end-to-end use case demonstrating:
1. **Model Install** (via Axon)
2. **Model Publish** (to MLOS Core instance)
3. **Model Inference** (via MLOS Core)

**Requirements:**
- Production-grade (no corners cut)
- Fully aligned with architecture
- Complete implementation (not stubs)

## Implementation Tasks

### Phase 1: Axon Publish Command

**Task:** Implement `axon publish` command with `--target` support

**Requirements:**
- Read model from `~/.axon/cache/`
- Copy to `/var/lib/mlos/models/` (or target location)
- Set proper permissions (`mlos:mlos`, `775`)
- Notify MLOS Core via API
- Support `--target` flag (default: `localhost`)

**Files to Modify:**
- `axon/cmd/axon/commands.go` - Add `publishCmd()`
- `axon/internal/cache/manager.go` - Add publish helper methods

### Phase 2: MLOS Core Model Repository Scanning

**Task:** Implement automatic model discovery on startup

**Requirements:**
- Scan `/var/lib/mlos/models/` for `manifest.yaml` files
- Auto-register discovered models
- Only scan production repository (not user caches)

**Files to Modify:**
- `core/src/mlos_core.c` - Add `mlos_scan_model_repository()`
- `core/src/mlos_main.c` - Call scanning on startup

### Phase 3: MLOS Core Model Upload API

**Task:** Implement `POST /models/upload` endpoint

**Requirements:**
- Accept model files via multipart/form-data
- Save to `/var/lib/mlos/models/`
- Auto-register uploaded model
- Return success/error response

**Files to Modify:**
- `core/api/http/http_server.c` - Add `mlos_http_handle_model_upload()`
- `core/api/http/http_server.c` - Add route handler

### Phase 4: Update Axon Register Command

**Task:** Update `axon register` to check published models first

**Requirements:**
- First check: `/var/lib/mlos/models/` (published models)
- Fallback: `~/.axon/cache/` (development models)
- Register with MLOS Core via API

**Files to Modify:**
- `axon/cmd/axon/commands.go` - Update `registerCmd()`

### Phase 5: Setup Scripts

**Task:** Create setup scripts for production repository

**Requirements:**
- Create `/var/lib/mlos/models/` directory
- Set proper permissions
- Create `mlos` user/group if needed

**Files to Create:**
- `core/scripts/setup-model-repository.sh`

### Phase 6: E2E Demo Script

**Task:** Create end-to-end demonstration script

**Requirements:**
- Install model with Axon
- Publish model to MLOS Core
- Run inference via MLOS Core API
- Verify all steps work correctly

**Files to Create:**
- `core/scripts/demo-e2e.sh`

## Implementation Order

1. ✅ **Setup Script** - Create repository directory
2. ✅ **MLOS Core Scanning** - Auto-discover published models
3. ✅ **MLOS Core Upload API** - Accept model uploads
4. ✅ **Axon Publish Command** - Publish models to repository
5. ✅ **Update Axon Register** - Check published models first
6. ✅ **E2E Demo Script** - Complete demonstration

## Success Criteria

- [ ] `axon install hf/bert-base-uncased@latest` works
- [ ] `axon publish hf/bert-base-uncased@latest --target localhost` works
- [ ] MLOS Core auto-discovers published model on startup
- [ ] `axon register hf/bert-base-uncased@latest` works (from published location)
- [ ] `curl -X POST http://localhost:8080/inference -d '{"model_id": "hf/bert-base-uncased@latest", "input": "..."}'` works
- [ ] All steps work together in E2E demo script

## Architecture Alignment

✅ **Per Patent US-63/861,527:**
- Model Package Format (MPF) via Axon manifests
- Model identifier: `namespace/name@version`
- OS-managed repository: `/var/lib/mlos/models/`
- API Gateway for programmatic interaction

✅ **Per Architecture Design:**
- Development cache: `~/.axon/cache/`
- Production repository: `/var/lib/mlos/models/`
- Explicit promotion: `axon publish`
- Auto-discovery: MLOS Core scans repository

