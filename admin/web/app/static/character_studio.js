(() => {
    const stage = document.getElementById('wow-model-viewer');
    const status = document.getElementById('character-render-status');
    if (!stage) return;

    const guid = stage.dataset.guid;
    const assetOrigin = `${window.location.protocol}//${window.location.hostname}:2999`;
    const contentPath = `${assetOrigin}/modelviewer/live/`;

    const setStatus = (message, kind = 'info') => {
        if (!status) return;
        status.textContent = message;
        status.dataset.kind = kind;
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
        script.addEventListener('load', () => {
            script.dataset.loaded = '1';
            resolve();
        }, {once: true});
        script.addEventListener('error', () => reject(new Error(`Failed to load ${src}`)), {once: true});
        document.head.appendChild(script);
    });

    const viewerSlot = (equipmentSlot) => ({
        0: 1,
        2: 3,
        3: 4,
        4: 5,
        5: 6,
        6: 7,
        7: 8,
        8: 9,
        9: 10,
        14: 15,
        15: 21,
        16: 22,
        17: 18,
        18: 19,
    })[equipmentSlot];

    const buildViewerCharacter = (data) => {
        const items = (data.equipment || [])
            .map((item) => {
                const slot = viewerSlot(Number(item.slot));
                if (!slot || !item.display_id) return null;
                return [slot, Number(item.display_id)];
            })
            .filter(Boolean);

        // AzerothCore/WotLK stores 0=male, 1=female. wow-model-viewer expects 0=female, 1=male.
        const viewerGender = Number(data.gender) === 1 ? 0 : 1;

        return {
            race: Number(data.race),
            gender: viewerGender,
            skin: Number(data.appearance.skin),
            face: Number(data.appearance.face),
            hairStyle: Number(data.appearance.hair_style),
            hairColor: Number(data.appearance.hair_color),
            facialStyle: Number(data.appearance.facial_style),
            items,
        };
    };

    async function startRenderer() {
        try {
            setStatus('Loading character data...');
            const response = await fetch(`/characters/${encodeURIComponent(guid)}/render-data`, {cache: 'no-store'});
            if (!response.ok) throw new Error(`Render data returned HTTP ${response.status}`);
            const data = await response.json();

            setStatus('Connecting to the cached WoW model asset service...');
            window.CONTENT_PATH = contentPath;
            window.WOTLK_TO_RETAIL_DISPLAY_ID_API = 'https://wotlk.murlocvillage.com/api/items';

            if (!window.jQuery) {
                await loadScript('https://code.jquery.com/jquery-3.5.1.min.js');
            }
            await loadScript(`${contentPath}viewer/viewer.min.js`);

            setStatus('Building the real 3D character model...');
            const module = await import('https://cdn.jsdelivr.net/npm/wow-model-viewer@1.5.3/index.js');
            const character = buildViewerCharacter(data);
            const model = await module.generateModels(1.35, '#wow-model-viewer', character);
            window.jmodCharacterModel = model;

            try { model.setDistance(2); } catch (_) {}
            setStatus(`Live 3D render loaded: ${data.name}`, 'ok');
        } catch (error) {
            console.error('JMod character renderer failed', error);
            setStatus(
                `3D renderer unavailable: ${error.message}. Make sure the JMod model asset proxy is running on port 2999, then refresh.`,
                'error'
            );
            stage.classList.add('render-failed');
        }
    }

    startRenderer();
})();
