(() => {
    const stage = document.getElementById('wow-model-viewer');
    const renderStatus = document.getElementById('character-render-status');
    const actionStatus = document.getElementById('studio-action-status');
    if (!stage) return;

    const guid = stage.dataset.guid;
    const characterName = stage.dataset.character;
    const assetOrigin = `${window.location.protocol}//${window.location.hostname}:2999`;
    const contentPath = `${assetOrigin}/modelviewer/live/`;

    let renderData = null;
    let viewerModule = null;
    let activeModel = null;
    let selectedGear = null;
    let selectedSpell = null;
    const previewOverrides = new Map();
    const timers = new WeakMap();

    const slotNames = {
        0: 'Head', 2: 'Shoulders', 4: 'Chest', 5: 'Waist', 6: 'Legs', 7: 'Feet',
        8: 'Wrists', 9: 'Hands', 14: 'Back', 15: 'Main Hand', 16: 'Off Hand',
        17: 'Ranged / Relic', 18: 'Tabard'
    };

    const allowedInventoryTypes = {
        0: [1], 2: [3], 4: [5, 20], 5: [6], 6: [7], 7: [8], 8: [9], 9: [10],
        14: [16], 15: [13, 17, 21], 16: [13, 14, 22, 23], 17: [15, 25, 26, 28], 18: [19]
    };

    const setRenderStatus = (message, kind = 'info') => {
        if (!renderStatus) return;
        renderStatus.textContent = message;
        renderStatus.dataset.kind = kind;
    };

    const setActionStatus = (message, kind = 'info') => {
        if (!actionStatus) return;
        actionStatus.style.display = 'block';
        actionStatus.textContent = message;
        actionStatus.dataset.kind = kind;
    };

    const loadScript = (src) => new Promise((resolve, reject) => {
        const existing = [...document.scripts].find((script) => script.src === src);
        if (existing) {
            if (existing.dataset.loaded === '1') resolve();
            else {
                existing.addEventListener('load', resolve, {once: true});
                existing.addEventListener('error', reject, {once: true});
            }
            return;
        }
        const script = document.createElement('script');
        script.src = src;
        script.async = true;
        script.addEventListener('load', () => { script.dataset.loaded = '1'; resolve(); }, {once: true});
        script.addEventListener('error', () => reject(new Error(`Failed to load ${src}`)), {once: true});
        document.head.appendChild(script);
    });

    const baseViewerSlot = (equipmentSlot) => ({
        0: 1, 2: 3, 3: 4, 4: 5, 5: 6, 6: 7, 7: 8, 8: 9, 9: 10,
        14: 15, 15: 21, 16: 22, 17: 18, 18: 19,
    })[equipmentSlot];

    const viewerSlotForItem = (item) => {
        const equipmentSlot = Number(item.slot);
        const inventoryType = Number(item.inventory_type || 0);
        // wow-model-viewer has a dedicated slot for robe-style chest pieces.
        if (equipmentSlot === 4 && inventoryType === 20) return 20;
        return baseViewerSlot(equipmentSlot);
    };

    const mergedEquipment = () => {
        const bySlot = new Map((renderData?.equipment || []).map((item) => [Number(item.slot), item]));
        for (const [slot, item] of previewOverrides.entries()) bySlot.set(Number(slot), item);
        return [...bySlot.values()];
    };

    const buildViewerCharacter = (data, equipment) => {
        const items = equipment
            .map((item) => {
                const slot = viewerSlotForItem(item);
                if (!slot || !item.display_id) return null;
                return [slot, Number(item.display_id)];
            })
            .filter(Boolean);
        const viewerGender = Number(data.gender) === 1 ? 0 : 1;
        return {
            race: Number(data.race), gender: viewerGender,
            skin: Number(data.appearance.skin), face: Number(data.appearance.face),
            hairStyle: Number(data.appearance.hair_style), hairColor: Number(data.appearance.hair_color),
            facialStyle: Number(data.appearance.facial_style), items,
        };
    };

    async function renderCharacter(equipment = mergedEquipment()) {
        if (!viewerModule || !renderData) return;
        setRenderStatus('Rendering loadout...');
        try {
            if (activeModel) {
                try { activeModel.destroy?.(); } catch (_) {}
                try { activeModel.dispose?.(); } catch (_) {}
            }
            stage.innerHTML = '';
            stage.classList.remove('render-failed');
            const character = buildViewerCharacter(renderData, equipment);
            activeModel = await viewerModule.generateModels(1.35, '#wow-model-viewer', character);
            window.jmodCharacterModel = activeModel;
            try { activeModel.setDistance(2); } catch (_) {}
            const overrideCount = previewOverrides.size;
            setRenderStatus(
                overrideCount ? `Live preview loaded with ${overrideCount} gear override${overrideCount === 1 ? '' : 's'}.` : `Live 3D render loaded: ${renderData.name}`,
                'ok'
            );
        } catch (error) {
            console.error('JMod character renderer failed', error);
            setRenderStatus(`3D renderer unavailable: ${error.message}`, 'error');
            stage.classList.add('render-failed');
        }
    }

    async function updatePreviewItem(item) {
        if (!activeModel) throw new Error('The 3D character is not ready yet.');
        const viewerSlot = viewerSlotForItem(item);
        const displayId = Number(item.display_id || 0);
        if (!viewerSlot || !displayId) throw new Error('That item does not have a renderable slot/display ID.');

        // The viewer exposes a live equipment update API. Use it instead of rebuilding
        // the whole model, which can leave old geosets/materials cached in the viewer.
        if (typeof activeModel.updateItemViewer === 'function') {
            await Promise.resolve(activeModel.updateItemViewer(viewerSlot, displayId, 0));
            return;
        }

        // Older viewer builds do not expose updateItemViewer, so retain the safe fallback.
        await renderCharacter();
    }

    async function startRenderer() {
        try {
            setRenderStatus('Loading character data...');
            const response = await fetch(`/characters/${encodeURIComponent(guid)}/render-data`, {cache: 'no-store'});
            if (!response.ok) throw new Error(`Render data returned HTTP ${response.status}`);
            renderData = await response.json();

            setRenderStatus('Connecting to the cached WoW model asset service...');
            window.CONTENT_PATH = contentPath;
            window.WOTLK_TO_RETAIL_DISPLAY_ID_API = 'https://wotlk.murlocvillage.com/api/items';
            if (!window.jQuery) await loadScript('https://code.jquery.com/jquery-3.5.1.min.js');
            await loadScript(`${contentPath}viewer/viewer.min.js`);
            viewerModule = await import('https://cdn.jsdelivr.net/npm/wow-model-viewer@1.5.3/index.js');
            await renderCharacter(renderData.equipment || []);
        } catch (error) {
            console.error('JMod character renderer startup failed', error);
            setRenderStatus(`3D renderer unavailable: ${error.message}. Make sure the model asset proxy is running on port 2999, then refresh.`, 'error');
            stage.classList.add('render-failed');
        }
    }

    const catalogSearch = async (type, query) => {
        const params = new URLSearchParams({type, q: query || ''});
        const response = await fetch(`/jmod-tools/catalog-search?${params.toString()}`, {cache: 'no-store', headers: {Accept: 'application/json'}});
        if (!response.ok) throw new Error(`Catalog search returned HTTP ${response.status}`);
        const payload = await response.json();
        return payload.results || [];
    };

    const executeJmod = async (command, value, count = 1) => {
        const form = new FormData();
        form.set('command', command);
        form.set('character', characterName);
        form.set('value', String(value));
        form.set('count', String(count));
        const response = await fetch('/jmod-tools', {method: 'POST', body: form, cache: 'no-store'});
        const html = await response.text();
        if (!response.ok) throw new Error(`JMod returned HTTP ${response.status}`);
        const doc = new DOMParser().parseFromString(html, 'text/html');
        const error = doc.querySelector('.error-message');
        if (error) throw new Error(error.textContent.trim());
        const success = doc.querySelector('.ok-message');
        return success?.textContent.trim() || `Executed ${command}.`;
    };

    const renderSelection = (element, row, type) => {
        if (!element) return;
        if (!row) { element.classList.remove('open'); element.innerHTML = ''; return; }
        const meta = row.metadata && typeof row.metadata === 'object' ? row.metadata : {};
        const pieces = [`${type.toUpperCase()} ID ${row.id}`];
        if (row.rank) pieces.push(row.rank);
        if (row.level) pieces.push(`Required level ${row.level}`);
        if (meta.item_level) pieces.push(`Item level ${meta.item_level}`);
        if (meta.display_id) pieces.push(`Display ${meta.display_id}`);
        if (row.quality !== null && row.quality !== undefined) pieces.push(`Quality ${row.quality}`);
        element.innerHTML = '';
        const title = document.createElement('strong'); title.textContent = `${row.name} [${row.id}]`; element.appendChild(title);
        const details = document.createElement('div'); details.textContent = pieces.join(' · '); element.appendChild(details);
        if (row.description) { const desc = document.createElement('div'); desc.style.marginTop = '6px'; desc.textContent = row.description; element.appendChild(desc); }
        element.classList.add('open');
    };

    const fillResults = (box, rows, onChoose, type) => {
        box.innerHTML = '';
        if (!rows.length) { box.innerHTML = '<div class="lookup-empty">No compatible catalog matches.</div>'; box.classList.add('open'); return; }
        for (const row of rows) {
            const button = document.createElement('button'); button.type = 'button'; button.className = 'lookup-result';
            const strong = document.createElement('strong'); strong.textContent = `${row.name} [${row.id}]`; button.appendChild(strong);
            const meta = row.metadata && typeof row.metadata === 'object' ? row.metadata : {};
            const bits = [];
            if (row.rank) bits.push(row.rank);
            if (row.level) bits.push(`Level ${row.level}`);
            if (meta.item_level) bits.push(`iLvl ${meta.item_level}`);
            if (meta.display_id) bits.push(`Display ${meta.display_id}`);
            if (row.verified) bits.push('verified');
            const small = document.createElement('small'); small.textContent = bits.length ? bits.join(' · ') : `${type} ID ${row.id}`; button.appendChild(small);
            button.addEventListener('mousedown', (event) => { event.preventDefault(); onChoose(row); box.classList.remove('open'); });
            box.appendChild(button);
        }
        box.classList.add('open');
    };

    function initGearLab() {
        const slot = document.getElementById('gear-slot');
        const input = document.getElementById('gear-search');
        const box = document.getElementById('gear-results');
        const selection = document.getElementById('gear-selection');
        const preview = document.getElementById('preview-gear');
        const mail = document.getElementById('mail-gear');
        const planned = document.getElementById('planned-gear');
        const mailLoadout = document.getElementById('mail-loadout');
        const reset = document.getElementById('reset-loadout');
        if (!slot || !input || !box) return;

        const updatePlanned = () => {
            planned.innerHTML = '';
            if (!previewOverrides.size) { planned.innerHTML = '<div class="empty">No preview overrides yet.</div>'; return; }
            for (const [slotId, row] of [...previewOverrides.entries()].sort((a, b) => a[0] - b[0])) {
                const line = document.createElement('div'); line.className = 'planned-row';
                line.innerHTML = `<span class="planned-slot"></span><strong></strong><span class="planned-id"></span>`;
                line.querySelector('.planned-slot').textContent = slotNames[slotId] || `Slot ${slotId}`;
                line.querySelector('strong').textContent = row.name;
                line.querySelector('.planned-id').textContent = `#${row.id}`;
                planned.appendChild(line);
            }
        };

        const choose = (row) => {
            const meta = row.metadata && typeof row.metadata === 'object' ? row.metadata : {};
            selectedGear = {...row, slot: Number(slot.value), display_id: Number(meta.display_id || 0), item_level: Number(meta.item_level || 0), inventory_type: Number(meta.inventory_type || 0)};
            input.value = `${row.name} [${row.id}]`;
            renderSelection(selection, row, 'item');
        };

        const refresh = async () => {
            try {
                const rows = await catalogSearch('item', input.value.trim());
                const allowed = allowedInventoryTypes[Number(slot.value)] || [];
                const compatible = rows.filter((row) => {
                    const meta = row.metadata && typeof row.metadata === 'object' ? row.metadata : {};
                    return allowed.includes(Number(meta.inventory_type));
                });
                fillResults(box, compatible, choose, 'item');
            } catch (error) { box.innerHTML = `<div class="lookup-empty">${error.message}</div>`; box.classList.add('open'); }
        };

        input.addEventListener('focus', refresh);
        input.addEventListener('input', () => { selectedGear = null; renderSelection(selection, null, 'item'); clearTimeout(timers.get(input)); timers.set(input, setTimeout(refresh, 160)); });
        slot.addEventListener('change', () => { selectedGear = null; input.value = ''; renderSelection(selection, null, 'item'); refresh(); });

        preview?.addEventListener('click', async () => {
            if (!selectedGear || !selectedGear.display_id) return setActionStatus('Choose a compatible gear result with a display ID first.', 'error');
            const previewItem = {...selectedGear, slot: Number(slot.value)};
            previewOverrides.set(Number(slot.value), previewItem);
            updatePlanned();
            try {
                setRenderStatus(`Applying ${selectedGear.name}...`);
                await updatePreviewItem(previewItem);
                const overrideCount = previewOverrides.size;
                setRenderStatus(`Live preview loaded with ${overrideCount} gear override${overrideCount === 1 ? '' : 's'}.`, 'ok');
                setActionStatus(`Previewing ${selectedGear.name} in ${slotNames[Number(slot.value)]}.`, 'ok');
            } catch (error) {
                setRenderStatus(`Preview failed: ${error.message}`, 'error');
                setActionStatus(error.message, 'error');
            }
        });

        mail?.addEventListener('click', async () => {
            if (!selectedGear) return setActionStatus('Choose an item first.', 'error');
            try { setActionStatus(`Mailing ${selectedGear.name} to ${characterName}...`); const msg = await executeJmod('item', selectedGear.id, 1); setActionStatus(msg, 'ok'); }
            catch (error) { setActionStatus(error.message, 'error'); }
        });

        mailLoadout?.addEventListener('click', async () => {
            if (!previewOverrides.size) return setActionStatus('Build a preview loadout first.', 'error');
            try {
                let sent = 0;
                setActionStatus(`Mailing ${previewOverrides.size} planned gear items to ${characterName}...`);
                for (const row of previewOverrides.values()) { await executeJmod('item', row.id, 1); sent += 1; }
                setActionStatus(`Mailed ${sent} planned gear items to ${characterName}.`, 'ok');
            } catch (error) { setActionStatus(error.message, 'error'); }
        });

        reset?.addEventListener('click', async () => { previewOverrides.clear(); updatePlanned(); await renderCharacter(renderData?.equipment || []); setActionStatus('Gear preview reset to the character\'s currently equipped items.', 'ok'); });
    }

    function initSpellTraining() {
        const input = document.getElementById('spell-search');
        const box = document.getElementById('spell-results');
        const selection = document.getElementById('spell-selection');
        const train = document.getElementById('train-spell');
        if (!input || !box) return;

        const choose = (row) => { selectedSpell = row; input.value = `${row.name} [${row.id}]`; renderSelection(selection, row, 'spell'); };
        const refresh = async () => {
            try { const rows = await catalogSearch('spell', input.value.trim()); fillResults(box, rows, choose, 'spell'); }
            catch (error) { box.innerHTML = `<div class="lookup-empty">${error.message}</div>`; box.classList.add('open'); }
        };
        input.addEventListener('focus', refresh);
        input.addEventListener('input', () => { selectedSpell = null; renderSelection(selection, null, 'spell'); clearTimeout(timers.get(input)); timers.set(input, setTimeout(refresh, 160)); });
        train?.addEventListener('click', async () => {
            if (!selectedSpell) return setActionStatus('Choose a spell from the catalog first.', 'error');
            try { setActionStatus(`Teaching ${selectedSpell.name} [${selectedSpell.id}] to ${characterName}...`); const msg = await executeJmod('train', selectedSpell.id, 1); setActionStatus(msg, 'ok'); }
            catch (error) { setActionStatus(error.message, 'error'); }
        });
    }

    document.addEventListener('click', (event) => {
        if (!event.target.closest('.lookup-wrap')) document.querySelectorAll('.lookup-results.open').forEach((el) => el.classList.remove('open'));
    });

    startRenderer();
    initGearLab();
    initSpellTraining();
})();
