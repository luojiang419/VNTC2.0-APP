const { createApp, ref, reactive, computed, onMounted, onUnmounted, nextTick, watch } = Vue;
const API_BASE = '/api';

const appOptions = {
    setup() {
        const csrfToken = ref(sessionStorage.getItem('csrf_token') || '');
        const isLoggedIn = computed(() => !!csrfToken.value);
        const theme = ref(document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light');
        const isDarkTheme = computed(() => theme.value === 'dark');
        const applyTheme = () => {
            document.documentElement.dataset.theme = theme.value;
            document.documentElement.style.colorScheme = theme.value;
        };
        const toggleTheme = () => {
            theme.value = isDarkTheme.value ? 'light' : 'dark';
            localStorage.setItem('vnts_theme', theme.value);
            applyTheme();
        };
        const currentView = ref('status');
        const loading = ref(false);
        const errorMsg = ref('');
        const modalErrorMsg = ref('');
        const networks = ref([]);
        const devices = ref([]);
        const currentNetworkCode = ref('');
        const loginForm = ref({ username: '', password: '' });
        const networkSearch = ref('');
        const deviceSearch = ref('');
        const username = ref(sessionStorage.getItem('username') || '');
        const peerServers = ref({ outbound: [], inbound: [] });
        const serverStatus = ref(null);
        const wireguardNetworkCode = ref('');
        const wireguardPeers = ref([]);
        const wireguardPeerIps = ref([]);
        const wireguardIpDrafts = reactive({});
        const showWireGuardPeerModal = ref(false);
        const emptyWireGuardRoute = () => ({
            lan_network: '', lan_prefix: '24', vnt_cli_ip: ''
        });
        const emptyWireGuardPeerForm = () => ({
            network_code: '', peer_id: '', public_key: '', enabled: true, dns_inherited: true,
            dns_servers: '', persistent_keepalive: 25, routes: [emptyWireGuardRoute()]
        });
        const wireguardPeerForm = ref(emptyWireGuardPeerForm());
        const wireguardEditingPeer = ref(null);
        const wireguardPeerMode = ref('generated');
        const generatedWireGuardPeer = ref(null);
        const wireguardGeneratedPeerNew = ref(false);
        const wireguardPrivateKeyCopied = ref(false);
        const wireguardPrivateKeySaved = ref(false);
        const wireguardConfigCopied = ref(false);
        const wireguardConfigDownloaded = ref(false);
        const wireguardQrCanvas = ref(null);
        const generatedWireGuardConfig = computed(() => {
            const generated = generatedWireGuardPeer.value;
            if (generated?.client_config) return generated.client_config;
            if (!generated?.private_key || !generated.peer?.ip || !generated.server_public_key
                || !generated.endpoint || !generated.allowed_ips) {
                return '';
            }
            const dnsLine = generated.dns_servers?.length ? `DNS = ${generated.dns_servers.join(', ')}\n` : '';
            const keepalive = generated.persistent_keepalive ?? 25;
            return `[Interface]\nPrivateKey = ${generated.private_key}\nAddress = ${generated.peer.ip}/32\n${dnsLine}\n[Peer]\nPublicKey = ${generated.server_public_key}\nAllowedIPs = ${generated.allowed_ips}\nEndpoint = ${generated.endpoint}\nPersistentKeepalive = ${keepalive}\n`;
        });
        const generatedWireGuardConfigFilename = computed(() => {
            const peer = generatedWireGuardPeer.value?.peer;
            const normalized = (peer?.peer_id || '')
                .normalize('NFKD')
                .replace(/[^A-Za-z0-9._-]+/g, '-')
                .replace(/^-+|-+$/g, '')
                .slice(0, 48);
            const fallback = peer?.ip ? peer.ip.replaceAll('.', '-') : 'peer';
            return `wireguard-${normalized || fallback}.conf`;
        });

        // 网速计算相关状态
        let lastTrafficMap = {};
        let lastFetchTime = 0;
        let deviceRefreshTimer = null;
        const HISTORY_SIZE = 60;
        const speedHistoryMap = {};
        const expandedCharts = reactive({});

        // 路由管理
        const updateRoute = (view, networkCode = '') => {
            if (view === 'devices' && networkCode) {
                window.location.hash = `#/devices/${encodeURIComponent(networkCode)}`;
            } else if (view === 'servers') {
                window.location.hash = '#/servers';
            } else if (view === 'networks') {
                window.location.hash = '#/networks';
            } else if (view === 'wireguard') {
                window.location.hash = '#/wireguard';
            } else {
                window.location.hash = '#/status';
            }
        };

        const parseRoute = () => {
            const hash = window.location.hash.slice(1) || '/status';
            if (hash.startsWith('/devices/')) {
                const code = decodeURIComponent(hash.substring(9));
                if (code) {
                    currentNetworkCode.value = code;
                    currentView.value = 'devices';
                    return { view: 'devices', networkCode: code };
                }
            } else if (hash === '/servers') {
                currentView.value = 'servers';
                return { view: 'servers' };
            } else if (hash === '/networks') {
                currentView.value = 'networks';
                return { view: 'networks' };
            } else if (hash === '/wireguard') {
                currentView.value = 'wireguard';
                return { view: 'wireguard' };
            }
            currentView.value = 'status';
            return { view: 'status' };
        };

        const handleRouteChange = () => {
            if (!isLoggedIn.value) return;
            const route = parseRoute();
            if (route.view === 'status') {
                stopDeviceRefresh();
                fetchStatus();
            } else if (route.view === 'networks') {
                stopDeviceRefresh();
                fetchNetworks();
            } else if (route.view === 'devices' && route.networkCode) {
                selectNetwork(route.networkCode, false);
            } else if (route.view === 'servers') {
                stopDeviceRefresh();
                fetchPeerServers();
            } else if (route.view === 'wireguard') {
                stopDeviceRefresh();
                initializeWireGuardPage();
            }
        };

        // 网络表单
        const showNetworkModal = ref(false);
        const isEditMode = ref(false);
        const networkForm = ref({ network_code: '', gateway: '', netmask: 24, lease_duration: null });

        // 确认删除
        const showConfirmModal = ref(false);
        const confirmMessage = ref('');
        const deleteTarget = ref(null);
        const deleteType = ref(''); // 'network', 'device', 'server', or 'wireguard-peer'

        // 服务器表单
        const showAddServerModal = ref(false);
        const serverForm = ref({ server_addr: '' });

        const request = async (endpoint, options = {}) => {
            loading.value = true;
            modalErrorMsg.value = '';
            errorMsg.value = '';
            const headers = { 'Content-Type': 'application/json', ...options.headers };
            const method = (options.method || 'GET').toUpperCase();
            if (!['GET', 'HEAD', 'OPTIONS'].includes(method) && csrfToken.value) {
                headers['X-CSRF-Token'] = csrfToken.value;
            }
            try {
                const res = await fetch(`${API_BASE}${endpoint}`, {
                    ...options,
                    headers,
                    credentials: 'same-origin'
                });
                const json = await res.json().catch(() => ({ code: res.status, msg: '' }));
                if (res.status === 401 || json.code === 401) {
                    clearSession();
                    errorMsg.value = '登录已过期';
                    return null;
                }
                if (!res.ok || json.code !== 200) {
                    const status = Number(json.code) || res.status;
                    const title = {
                        400: '请求参数错误',
                        404: '资源不存在',
                        409: '操作冲突',
                        503: '服务暂不可用'
                    }[status] || '请求失败';
                    throw new Error(json.msg ? `${title}：${json.msg}` : title);
                }
                return (json.data !== null && json.data !== undefined) ? json.data : true;
            } catch (e) {
                modalErrorMsg.value = e.message;
                errorMsg.value = e.message;
                console.error(e);
                return null;
            } finally {
                loading.value = false;
            }
        };

        // 静默请求（不触发 loading 状态，用于自动刷新）
        const requestSilent = async (endpoint) => {
            const headers = { 'Content-Type': 'application/json' };
            try {
                const res = await fetch(`${API_BASE}${endpoint}`, {
                    headers,
                    credentials: 'same-origin'
                });
                const json = await res.json().catch(() => ({ code: res.status }));
                if (res.status === 401 || json.code === 401) {
                    clearSession();
                    return null;
                }
                if (json.code !== 200) return null;
                return (json.data !== null && json.data !== undefined) ? json.data : true;
            } catch (e) {
                console.error(e);
                return null;
            }
        };

        const formatDuration = (seconds) => {
            if (!seconds) return '-';
            if (seconds >= 86400) {
                const days = Math.floor(seconds / 86400);
                const hours = Math.floor((seconds % 86400) / 3600);
                return hours > 0 ? `${days}天${hours}小时` : `${days}天`;
            }
            if (seconds >= 3600) {
                const hours = Math.floor(seconds / 3600);
                const mins = Math.floor((seconds % 3600) / 60);
                return mins > 0 ? `${hours}小时${mins}分钟` : `${hours}小时`;
            }
            if (seconds >= 60) {
                return `${Math.floor(seconds / 60)}分钟`;
            }
            return `${seconds}秒`;
        };

        const formatSource = (source) => {
            const sourceMap = {
                'Config': '配置初始化',
                'Manual': '手动创建',
                'DeviceRegister': '设备注册'
            };
            return sourceMap[source] || source || '未知';
        };

        const getSourceColor = (source) => {
            const colorMap = {
                'Config': 'text-purple-600',
                'Manual': 'text-green-600',
                'DeviceRegister': 'text-orange-600'
            };
            return colorMap[source] || 'text-gray-600';
        };

        const handleLogin = async () => {
            const data = await request('/login', { method: 'POST', body: JSON.stringify(loginForm.value) });
            if (data && data.csrf_token) {
                csrfToken.value = data.csrf_token;
                sessionStorage.setItem('csrf_token', data.csrf_token);
                sessionStorage.setItem('username', loginForm.value.username);
                username.value = loginForm.value.username;
                updateRoute('status');
                fetchStatus();
            }
        };

        const clearSession = () => {
            csrfToken.value = '';
            sessionStorage.removeItem('csrf_token');
            sessionStorage.removeItem('username');
            username.value = '';
            loginForm.value = { username: '', password: '' };
            currentView.value = 'status';
            serverStatus.value = null;
            wireguardNetworkCode.value = '';
            wireguardPeers.value = [];
            wireguardPeerIps.value = [];
            Object.keys(wireguardIpDrafts).forEach(key => delete wireguardIpDrafts[key]);
            generatedWireGuardPeer.value = null;
            wireguardGeneratedPeerNew.value = false;
            wireguardEditingPeer.value = null;
            wireguardPrivateKeyCopied.value = false;
            wireguardPrivateKeySaved.value = false;
            wireguardConfigCopied.value = false;
            wireguardConfigDownloaded.value = false;
            if (wireguardQrCanvas.value) {
                wireguardQrCanvas.value.width = 0;
                wireguardQrCanvas.value.height = 0;
            }
            showWireGuardPeerModal.value = false;
            stopDeviceRefresh();
        };

        const logout = async () => {
            try {
                await fetch(`${API_BASE}/logout`, {
                    method: 'POST',
                    credentials: 'same-origin'
                });
            } finally {
                clearSession();
            }
        };

        const fetchNetworks = async () => {
            if (!isLoggedIn.value) return;
            const data = await request('/networks');
            if (data) networks.value = data;
            return data;
        };

        const fetchStatus = async () => {
            if (!isLoggedIn.value) return;
            const data = await request('/status');
            if (data) serverStatus.value = data;
        };

        const statusListeners = computed(() => {
            if (!serverStatus.value) return [];
            const listeners = serverStatus.value.listeners;
            return [
                { label: 'Web 管理', value: listeners.web },
                { label: 'VNT TCP', value: listeners.vnt_tcp },
                { label: 'VNT QUIC', value: listeners.vnt_quic },
                { label: 'VNT WebSocket', value: listeners.vnt_websocket },
                { label: '服务器互联 QUIC', value: listeners.peer_server_quic }
            ];
        });

        const fetchPeerServers = async () => {
            if (!isLoggedIn.value) return;
            const data = await request('/peer_servers');
            if (data) peerServers.value = data;
        };

        // 停止设备自动刷新
        const stopDeviceRefresh = () => {
            if (deviceRefreshTimer) {
                clearInterval(deviceRefreshTimer);
                deviceRefreshTimer = null;
            }
        };

        // 重置网速计算状态
        const resetSpeedState = () => {
            lastTrafficMap = {};
            lastFetchTime = 0;
            Object.keys(speedHistoryMap).forEach(k => delete speedHistoryMap[k]);
            Object.keys(expandedCharts).forEach(k => delete expandedCharts[k]);
        };

        // 静默刷新设备列表并计算网速
        const fetchDevicesSilent = async () => {
            if (!isLoggedIn.value || !currentNetworkCode.value) return;
            const data = await requestSilent(`/devices?code=${encodeURIComponent(currentNetworkCode.value)}`);
            if (!data) return;

            const now = Date.now();
            const elapsed = lastFetchTime > 0 ? (now - lastFetchTime) / 1000 : 0;
            const newTrafficMap = {};

            for (const dev of data) {
                const key = dev.device_id;
                const prev = lastTrafficMap[key];
                if (prev && elapsed > 0) {
                    const txDiff = Math.max(0, (dev.tx_bytes || 0) - prev.tx_bytes);
                    const rxDiff = Math.max(0, (dev.rx_bytes || 0) - prev.rx_bytes);
                    dev.tx_speed = Math.round(txDiff / elapsed);
                    dev.rx_speed = Math.round(rxDiff / elapsed);
                } else {
                    dev.tx_speed = 0;
                    dev.rx_speed = 0;
                }
                newTrafficMap[key] = { tx_bytes: dev.tx_bytes || 0, rx_bytes: dev.rx_bytes || 0 };
            }

            lastTrafficMap = newTrafficMap;
            lastFetchTime = now;
            devices.value = data;

            // 记录按 IP 分组的网速历史
            const ipSpeedMap = {};
            for (const dev of data) {
                const ip = dev.ip || `no-ip-${dev.device_id}`;
                if (!ipSpeedMap[ip]) ipSpeedMap[ip] = { tx: 0, rx: 0 };
                ipSpeedMap[ip].tx += dev.tx_speed || 0;
                ipSpeedMap[ip].rx += dev.rx_speed || 0;
            }
            for (const [ip, speed] of Object.entries(ipSpeedMap)) {
                if (!speedHistoryMap[ip]) speedHistoryMap[ip] = { tx: [], rx: [] };
                speedHistoryMap[ip].tx.push(speed.tx);
                speedHistoryMap[ip].rx.push(speed.rx);
                if (speedHistoryMap[ip].tx.length > HISTORY_SIZE) {
                    speedHistoryMap[ip].tx.shift();
                    speedHistoryMap[ip].rx.shift();
                }
            }

            // 重绘展开的图表
            nextTick(() => {
                for (const chartKey in expandedCharts) {
                    if (expandedCharts[chartKey]) drawChart(chartKey);
                }
            });
        };

        // 开始设备自动刷新
        const startDeviceRefresh = () => {
            stopDeviceRefresh();
            deviceRefreshTimer = setInterval(() => {
                if (document.visibilityState !== 'hidden') {
                    fetchDevicesSilent();
                }
            }, 3000);
        };

        const selectNetwork = async (code, updateHash = true) => {
            currentNetworkCode.value = code;
            devices.value = [];
            deviceSearch.value = '';
            currentView.value = 'devices';
            resetSpeedState();
            if (updateHash) {
                updateRoute('devices', code);
            }
            const data = await request(`/devices?code=${encodeURIComponent(code)}`);
            if (data) {
                // 初始化速度为0
                for (const dev of data) {
                    dev.tx_speed = 0;
                    dev.rx_speed = 0;
                    const key = dev.device_id;
                    lastTrafficMap[key] = { tx_bytes: dev.tx_bytes || 0, rx_bytes: dev.rx_bytes || 0 };
                }
                lastFetchTime = Date.now();
                devices.value = data;
            }
            startDeviceRefresh();
        };

        const navigateToNetworks = () => {
            stopDeviceRefresh();
            resetSpeedState();
            updateRoute('networks');
            fetchNetworks();
        };

        const navigateToStatus = () => {
            stopDeviceRefresh();
            resetSpeedState();
            updateRoute('status');
            fetchStatus();
        };

        const navigateToServers = () => {
            stopDeviceRefresh();
            resetSpeedState();
            updateRoute('servers');
            fetchPeerServers();
        };

        const navigateToWireGuard = () => {
            stopDeviceRefresh();
            resetSpeedState();
            if (currentView.value === 'wireguard') {
                initializeWireGuardPage();
            } else {
                updateRoute('wireguard');
            }
        };

        // WireGuard 管理
        const wireguardPeerKey = (peer) => `${peer.network_code}::${peer.peer_id}`;

        const wireguardAllocationKey = (allocation) =>
            `${allocation.network_code || wireguardNetworkCode.value}::${allocation.peer_id}`;

        const wireguardIpMap = computed(() => Object.fromEntries(
            wireguardPeerIps.value.map(allocation => [wireguardAllocationKey(allocation), allocation.ip])
        ));

        const wireguardPeerRowClass = (peer, index) => [
            'hover:bg-gray-50',
            index > 0 && wireguardPeers.value[index - 1]?.network_code !== peer.network_code
                ? 'border-t-2 border-gray-200'
                : ''
        ];

        const initializeWireGuardPage = async () => {
            const availableNetworks = await fetchNetworks();
            if (!Array.isArray(availableNetworks) || availableNetworks.length === 0) {
                wireguardNetworkCode.value = '';
                wireguardPeers.value = [];
                wireguardPeerIps.value = [];
                return;
            }
            if (wireguardNetworkCode.value && !availableNetworks.some(net => net.network_code === wireguardNetworkCode.value)) {
                wireguardNetworkCode.value = '';
            }
            await fetchWireGuardData();
        };

        const fetchWireGuardData = async () => {
            wireguardPeers.value = [];
            wireguardPeerIps.value = [];
            Object.keys(wireguardIpDrafts).forEach(key => delete wireguardIpDrafts[key]);
            const query = wireguardNetworkCode.value
                ? `?network_code=${encodeURIComponent(wireguardNetworkCode.value)}`
                : '';
            const peers = await request(`/wireguard/peers${query}`);
            if (!Array.isArray(peers)) return;
            const allocations = await request(`/wireguard/peer_ips${query}`);
            if (!Array.isArray(allocations)) return;
            wireguardPeers.value = peers.slice().sort((left, right) =>
                left.network_code.localeCompare(right.network_code)
                || left.peer_id.localeCompare(right.peer_id)
            );
            wireguardPeerIps.value = allocations;
            const allocationMap = Object.fromEntries(
                allocations.map(allocation => [wireguardAllocationKey(allocation), allocation.ip])
            );
            Object.keys(wireguardIpDrafts).forEach(key => delete wireguardIpDrafts[key]);
            wireguardPeers.value.forEach(peer => {
                const key = wireguardPeerKey(peer);
                wireguardIpDrafts[key] = allocationMap[key] || peer.ip || '';
            });
        };

        const openWireGuardPeerModal = () => {
            wireguardPeerForm.value = {
                ...emptyWireGuardPeerForm(),
                network_code: wireguardNetworkCode.value || networks.value[0]?.network_code || ''
            };
            wireguardEditingPeer.value = null;
            wireguardPeerMode.value = 'generated';
            generatedWireGuardPeer.value = null;
            wireguardGeneratedPeerNew.value = false;
            wireguardPrivateKeyCopied.value = false;
            wireguardPrivateKeySaved.value = false;
            wireguardConfigCopied.value = false;
            wireguardConfigDownloaded.value = false;
            modalErrorMsg.value = '';
            showWireGuardPeerModal.value = true;
        };

        const closeWireGuardPeerModal = () => {
            if (generatedWireGuardPeer.value && wireguardGeneratedPeerNew.value) {
                modalErrorMsg.value = '请先确认已保存私钥，或选择“放弃并删除 Peer”。';
                return;
            }
            showWireGuardPeerModal.value = false;
            wireguardEditingPeer.value = null;
            clearGeneratedWireGuardPeer();
            modalErrorMsg.value = '';
        };

        const normalizeWireGuardRoute = (route) => {
            const rawLanNetwork = String(route?.lan_network || '').trim();
            const slashIndex = rawLanNetwork.indexOf('/');
            return {
                lan_network: slashIndex >= 0 ? rawLanNetwork.slice(0, slashIndex).trim() : rawLanNetwork,
                lan_prefix: slashIndex >= 0 ? rawLanNetwork.slice(slashIndex + 1).trim() || '24' : '24',
                vnt_cli_ip: String(route?.vnt_cli_ip || '').trim()
            };
        };

        const addWireGuardRoute = () => {
            wireguardPeerForm.value.routes.push(emptyWireGuardRoute());
        };

        const removeWireGuardRoute = (index) => {
            if (wireguardPeerForm.value.routes.length <= 1) {
                wireguardPeerForm.value.routes[0] = emptyWireGuardRoute();
                return;
            }
            wireguardPeerForm.value.routes.splice(index, 1);
        };

        const parseWireGuardRoutes = (routes) => routes
            .map((route, index) => {
                const lanNetwork = String(route?.lan_network || '').trim();
                const lanPrefix = String(route?.lan_prefix || '24').trim();
                const vntCliIp = String(route?.vnt_cli_ip || '').trim();
                if (!lanNetwork && !vntCliIp) return null;
                if (!lanNetwork || !vntCliIp) {
                    throw new Error(`第 ${index + 1} 条路由请同时填写局域网 CIDR 和 VNT 客户端虚拟 IP。`);
                }
                if (!/^\d{1,2}$/.test(lanPrefix) || Number(lanPrefix) < 0 || Number(lanPrefix) > 32) {
                    throw new Error(`第 ${index + 1} 条路由的 CIDR 前缀无效。`);
                }
                return { lan_network: `${lanNetwork}/${lanPrefix}`, vnt_cli_ip: vntCliIp };
            })
            .filter(Boolean);

        const wireguardProfilePayload = () => ({
            dns_servers: wireguardPeerForm.value.dns_inherited
                ? null
                : wireguardPeerForm.value.dns_servers.split(/[\s,]+/).map(value => value.trim()).filter(Boolean),
            persistent_keepalive: Number(wireguardPeerForm.value.persistent_keepalive),
            routes: parseWireGuardRoutes(wireguardPeerForm.value.routes)
        });

        const openWireGuardProfileModal = (peer) => {
            wireguardEditingPeer.value = peer;
            wireguardPeerForm.value = {
                network_code: peer.network_code,
                peer_id: peer.peer_id,
                public_key: peer.public_key,
                enabled: peer.enabled,
                dns_inherited: peer.dns_inherited,
                dns_servers: peer.dns_servers?.join(', ') || '',
                persistent_keepalive: peer.persistent_keepalive ?? 25,
                routes: (peer.routes || []).length
                    ? peer.routes.map(normalizeWireGuardRoute)
                    : [emptyWireGuardRoute()]
            };
            generatedWireGuardPeer.value = null;
            wireguardGeneratedPeerNew.value = false;
            modalErrorMsg.value = '';
            showWireGuardPeerModal.value = true;
        };

        const openStoredWireGuardConfig = async (peer) => {
            const endpoint = `/wireguard/peers/config?network_code=${encodeURIComponent(peer.network_code)}&peer_id=${encodeURIComponent(peer.peer_id)}`;
            const generated = await request(endpoint);
            if (!generated) return;
            wireguardEditingPeer.value = null;
            generatedWireGuardPeer.value = generated;
            wireguardGeneratedPeerNew.value = false;
            wireguardPrivateKeySaved.value = true;
            wireguardConfigCopied.value = false;
            wireguardConfigDownloaded.value = false;
            modalErrorMsg.value = '';
            showWireGuardPeerModal.value = true;
            await renderGeneratedWireGuardQrCode();
        };

        const submitWireGuardPeer = async () => {
            const peerId = wireguardPeerForm.value.peer_id.trim();
            if (!peerId) {
                modalErrorMsg.value = '请输入设备名称。';
                return;
            }
            let profile;
            try {
                profile = wireguardProfilePayload();
            } catch (error) {
                modalErrorMsg.value = error.message;
                return;
            }
            if (!Number.isInteger(profile.persistent_keepalive) || profile.persistent_keepalive < 0 || profile.persistent_keepalive > 65535) {
                modalErrorMsg.value = 'PersistentKeepalive 必须是 0 到 65535 之间的整数。';
                return;
            }
            const targetNetworkCode = wireguardEditingPeer.value
                ? wireguardEditingPeer.value.network_code
                : wireguardPeerForm.value.network_code.trim();
            if (!targetNetworkCode) {
                modalErrorMsg.value = '请选择网络。';
                return;
            }
            if (wireguardEditingPeer.value) {
                const result = await request('/wireguard/peers/profile', {
                    method: 'PUT',
                    body: JSON.stringify({
                        network_code: wireguardEditingPeer.value.network_code,
                        peer_id: wireguardEditingPeer.value.peer_id,
                        ...profile
                    })
                });
                if (result) {
                    showWireGuardPeerModal.value = false;
                    wireguardEditingPeer.value = null;
                    await fetchWireGuardData();
                }
                return;
            }
            if (wireguardPeerMode.value === 'generated') {
                const generated = await request('/wireguard/peers/generated', {
                    method: 'POST',
                    body: JSON.stringify({
                        network_code: targetNetworkCode,
                        peer_id: peerId,
                        enabled: wireguardPeerForm.value.enabled,
                        ...profile
                    })
                });
                if (generated) {
                    generatedWireGuardPeer.value = generated;
                    wireguardGeneratedPeerNew.value = true;
                    wireguardPrivateKeyCopied.value = false;
                    wireguardPrivateKeySaved.value = false;
                    wireguardConfigCopied.value = false;
                    wireguardConfigDownloaded.value = false;
                    await renderGeneratedWireGuardQrCode();
                }
                return;
            }

            const result = await request('/wireguard/peers', {
                method: 'POST',
                body: JSON.stringify({
                    network_code: targetNetworkCode,
                    peer_id: peerId,
                    public_key: wireguardPeerForm.value.public_key.trim(),
                    enabled: wireguardPeerForm.value.enabled,
                    ...profile
                })
            });
            if (result) {
                closeWireGuardPeerModal();
                await fetchWireGuardData();
            }
        };

        const copyTextToClipboard = async (text) => {
            if (navigator.clipboard && window.isSecureContext) {
                await navigator.clipboard.writeText(text);
                return;
            }
            const input = document.createElement('textarea');
            input.value = text;
            input.setAttribute('readonly', '');
            input.className = 'fixed left-0 top-0 opacity-0 pointer-events-none';
            document.body.appendChild(input);
            input.select();
            const copied = document.execCommand('copy');
            document.body.removeChild(input);
            if (!copied) throw new Error('浏览器拒绝复制操作');
        };

        const copyGeneratedWireGuardPrivateKey = async () => {
            const privateKey = generatedWireGuardPeer.value?.private_key;
            if (!privateKey) return;
            try {
                await copyTextToClipboard(privateKey);
                wireguardPrivateKeyCopied.value = true;
                modalErrorMsg.value = '';
            } catch (error) {
                modalErrorMsg.value = `复制失败：${error.message || '请手动选择私钥复制'}`;
            }
        };

        const copyGeneratedWireGuardConfig = async () => {
            if (!generatedWireGuardConfig.value) return;
            try {
                await copyTextToClipboard(generatedWireGuardConfig.value);
                wireguardConfigCopied.value = true;
                modalErrorMsg.value = '';
            } catch (error) {
                modalErrorMsg.value = `复制配置失败：${error.message || '请手动选择配置复制'}`;
            }
        };

        const downloadGeneratedWireGuardConfig = () => {
            if (!generatedWireGuardConfig.value) return;
            const blob = new Blob([generatedWireGuardConfig.value], { type: 'text/plain;charset=utf-8' });
            const url = URL.createObjectURL(blob);
            const link = document.createElement('a');
            link.href = url;
            link.download = generatedWireGuardConfigFilename.value;
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
            URL.revokeObjectURL(url);
            wireguardConfigDownloaded.value = true;
            modalErrorMsg.value = '';
        };

        const renderGeneratedWireGuardQrCode = async () => {
            await nextTick();
            if (!generatedWireGuardConfig.value || !wireguardQrCanvas.value) return;
            try {
                if (!window.QRCode?.toCanvas) throw new Error('二维码组件未加载');
                await window.QRCode.toCanvas(wireguardQrCanvas.value, generatedWireGuardConfig.value, {
                    width: 240,
                    margin: 2,
                    errorCorrectionLevel: 'M'
                });
            } catch (error) {
                modalErrorMsg.value = `二维码生成失败：${error.message || '请改用下载配置'}`;
            }
        };

        const clearGeneratedWireGuardPeer = () => {
            if (wireguardQrCanvas.value) {
                wireguardQrCanvas.value.width = 0;
                wireguardQrCanvas.value.height = 0;
            }
            generatedWireGuardPeer.value = null;
            wireguardGeneratedPeerNew.value = false;
            wireguardPrivateKeyCopied.value = false;
            wireguardPrivateKeySaved.value = false;
            wireguardConfigCopied.value = false;
            wireguardConfigDownloaded.value = false;
        };

        const finishGeneratedWireGuardPeer = async () => {
            if (!generatedWireGuardPeer.value || (wireguardGeneratedPeerNew.value && !wireguardPrivateKeySaved.value)) {
                modalErrorMsg.value = '请先确认已经下载配置、扫码导入或安全保存客户端私钥。';
                return;
            }
            clearGeneratedWireGuardPeer();
            showWireGuardPeerModal.value = false;
            modalErrorMsg.value = '';
            await fetchWireGuardData();
        };

        const discardGeneratedWireGuardPeer = async () => {
            if (!wireguardGeneratedPeerNew.value) return;
            const peer = generatedWireGuardPeer.value?.peer;
            if (!peer) return;
            if (!window.confirm(`确定放弃并删除 Peer “${peer.peer_id}”吗？刚生成的密钥将无法恢复。`)) {
                return;
            }
            const endpoint = `/wireguard/peers?network_code=${encodeURIComponent(peer.network_code)}&peer_id=${encodeURIComponent(peer.peer_id)}`;
            const result = await request(endpoint, { method: 'DELETE' });
            if (result) {
                clearGeneratedWireGuardPeer();
                showWireGuardPeerModal.value = false;
                modalErrorMsg.value = '';
                await fetchWireGuardData();
            }
        };

        const setWireGuardPeerEnabled = async (peer, enabled) => {
            const result = await request('/wireguard/peers/enabled', {
                method: 'PUT',
                body: JSON.stringify({
                    network_code: peer.network_code,
                    peer_id: peer.peer_id,
                    enabled
                })
            });
            if (result) await fetchWireGuardData();
        };

        const reserveWireGuardPeerIp = async (peer) => {
            const result = await request('/wireguard/peer_ips', {
                method: 'PUT',
                body: JSON.stringify({
                    network_code: peer.network_code,
                    peer_id: peer.peer_id,
                    ip: (wireguardIpDrafts[wireguardPeerKey(peer)] || '').trim()
                })
            });
            if (result) await fetchWireGuardData();
        };

        const releaseWireGuardPeerIp = async (peer) => {
            const endpoint = `/wireguard/peer_ips?network_code=${encodeURIComponent(peer.network_code)}&peer_id=${encodeURIComponent(peer.peer_id)}`;
            const result = await request(endpoint, { method: 'DELETE' });
            if (result) await fetchWireGuardData();
        };

        const confirmDeleteWireGuardPeer = (peer) => {
            deleteType.value = 'wireguard-peer';
            deleteTarget.value = peer;
            confirmMessage.value = `确定要删除 WireGuard peer "${peer.peer_id}" 吗？关联的保留 IP 将同时释放。`;
            modalErrorMsg.value = '';
            showConfirmModal.value = true;
        };

        const formatTimestamp = (seconds) => {
            if (!seconds) return '-';
            return new Date(seconds * 1000).toLocaleString('zh-CN', { hour12: false });
        };

        const wireguardStatusLabel = (status) => ({
            online: '在线', offline: '离线', disabled: '已禁用', unassigned: '未分配 IP'
        })[status] || '未知';

        const wireguardStatusClass = (status) => ({
            online: 'bg-green-100 text-green-800',
            offline: 'bg-gray-200 text-gray-600',
            disabled: 'bg-red-100 text-red-700',
            unassigned: 'bg-amber-100 text-amber-800'
        })[status] || 'bg-gray-100 text-gray-600';

        // 网络管理
        const openAddNetworkModal = () => {
            isEditMode.value = false;
            networkForm.value = { network_code: '', gateway: '', netmask: 24, lease_duration: null };
            modalErrorMsg.value = '';
            showNetworkModal.value = true;
        };

        const openEditNetworkModal = (net) => {
            isEditMode.value = true;
            networkForm.value = {
                network_code: net.network_code,
                gateway: net.gateway,
                netmask: net.netmask,
                lease_duration: net.lease_duration
            };
            modalErrorMsg.value = '';
            showNetworkModal.value = true;
        };

        const closeNetworkModal = () => {
            showNetworkModal.value = false;
        };

        const submitNetworkForm = async () => {
            const form = networkForm.value;
            let result;
            if (isEditMode.value) {
                result = await request(`/networks/${encodeURIComponent(form.network_code)}`, {
                    method: 'PUT',
                    body: JSON.stringify({
                        gateway: form.gateway,
                        netmask: form.netmask,
                        lease_duration: form.lease_duration
                    })
                });
            } else {
                const body = {
                    network_code: form.network_code,
                    gateway: form.gateway,
                    netmask: form.netmask
                };
                if (form.lease_duration) body.lease_duration = form.lease_duration;
                result = await request('/networks', { method: 'POST', body: JSON.stringify(body) });
            }
            if (result) {
                closeNetworkModal();
                fetchNetworks();
            }
        };

        // 删除确认
        const confirmDeleteNetwork = (net) => {
            deleteType.value = 'network';
            deleteTarget.value = net;
            confirmMessage.value = `确定要删除网络 "${net.network_code}" 吗？此操作不可撤销。`;
            modalErrorMsg.value = '';
            showConfirmModal.value = true;
        };

        const confirmDeleteDevice = (dev) => {
            deleteType.value = 'device';
            deleteTarget.value = dev;
            confirmMessage.value = `确定要删除设备 "${dev.device_name}" (${dev.device_id}) 吗？此操作不可撤销。`;
            modalErrorMsg.value = '';
            showConfirmModal.value = true;
        };

        const closeConfirmModal = () => {
            showConfirmModal.value = false;
            deleteTarget.value = null;
        };

        const executeDelete = async () => {
            if (deleteType.value === 'network') {
                const result = await request(`/networks/${encodeURIComponent(deleteTarget.value.network_code)}`, {
                    method: 'DELETE'
                });
                if (result) {
                    closeConfirmModal();
                    fetchNetworks();
                }
            } else if (deleteType.value === 'device') {
                const result = await request(
                    `/devices?code=${encodeURIComponent(currentNetworkCode.value)}&device_id=${encodeURIComponent(deleteTarget.value.device_id)}`,
                    { method: 'DELETE' }
                );
                if (result) {
                    closeConfirmModal();
                    selectNetwork(currentNetworkCode.value);
                }
            } else if (deleteType.value === 'server') {
                const result = await request(`/peer_servers/${encodeURIComponent(deleteTarget.value.addr)}`, {
                    method: 'DELETE'
                });
                if (result) {
                    closeConfirmModal();
                    fetchPeerServers();
                }
            } else if (deleteType.value === 'wireguard-peer') {
                const endpoint = `/wireguard/peers?network_code=${encodeURIComponent(deleteTarget.value.network_code)}&peer_id=${encodeURIComponent(deleteTarget.value.peer_id)}`;
                const result = await request(endpoint, { method: 'DELETE' });
                if (result) {
                    closeConfirmModal();
                    await fetchWireGuardData();
                }
            }
        };

        // 服务器管理
        const openAddServerModal = () => {
            serverForm.value = { server_addr: '' };
            modalErrorMsg.value = '';
            showAddServerModal.value = true;
        };

        const closeAddServerModal = () => {
            showAddServerModal.value = false;
        };

        const submitAddServer = async () => {
            const result = await request('/peer_servers', {
                method: 'POST',
                body: JSON.stringify(serverForm.value)
            });
            if (result) {
                closeAddServerModal();
                fetchPeerServers();
            }
        };

        const confirmDeleteServer = (server) => {
            deleteType.value = 'server';
            deleteTarget.value = server;
            confirmMessage.value = `确定要删除服务器 "${server.addr}" 吗？此操作将断开连接并从列表中移除。`;
            modalErrorMsg.value = '';
            showConfirmModal.value = true;
        };

        const filteredNetworks = computed(() => {
            const search = networkSearch.value.toLowerCase();
            return networks.value.filter(n => n.network_code.toLowerCase().includes(search));
        });

        const filteredDevices = computed(() => {
            const search = deviceSearch.value.toLowerCase();
            return devices.value.filter(d =>
                (d.ip && d.ip.includes(search)) ||
                d.device_id.toLowerCase().includes(search) ||
                d.device_name.toLowerCase().includes(search)
            );
        });

        // 合并相同IP的设备（本地和远程）
        const mergedDevices = computed(() => {
            const search = deviceSearch.value.toLowerCase();
            const filtered = devices.value.filter(d =>
                (d.ip && d.ip.includes(search)) ||
                d.device_id.toLowerCase().includes(search) ||
                d.device_name.toLowerCase().includes(search)
            );

            // 按IP分组
            const ipGroups = new Map();

            filtered.forEach(dev => {
                const ip = dev.ip || `no-ip-${dev.device_id}`;
                if (!ipGroups.has(ip)) {
                    ipGroups.set(ip, []);
                }
                ipGroups.get(ip).push(dev);
            });

            // 转换为数组并添加聚合信息
            const result = [];
            ipGroups.forEach((devs, ip) => {
                const hasOnline = devs.some(d => d.status === 'Online');
                const hasRemote = devs.some(d => d.status === 'Remote');
                const canDelete = devs.every(d => d.status !== 'Online' && d.status !== 'Remote');

                // 计算最佳延迟
                const latencies = devs.map(d => d.latency_ms).filter(l => l !== null && l !== undefined);
                const bestLatency = latencies.length > 0 ? Math.min(...latencies) : null;

                // 计算总流量
                const totalTxBytes = devs.reduce((sum, d) => sum + (d.tx_bytes || 0), 0);
                const totalRxBytes = devs.reduce((sum, d) => sum + (d.rx_bytes || 0), 0);

                // 计算总网速（前端计算）
                const totalTxSpeed = devs.reduce((sum, d) => sum + (d.tx_speed || 0), 0);
                const totalRxSpeed = devs.reduce((sum, d) => sum + (d.rx_speed || 0), 0);

                result.push({
                    ip: ip.startsWith('no-ip-') ? null : ip,
                    devices: devs,
                    hasOnline,
                    hasRemote,
                    canDelete,
                    bestLatency,
                    totalTxBytes,
                    totalRxBytes,
                    totalTxSpeed,
                    totalRxSpeed,
                    expanded: false
                });
            });

            return result;
        });

        // 切换展开状态（多来源展开）
        const toggleExpand = (group) => {
            group.expanded = !group.expanded;
        };

        // 切换网速历史图表
        const toggleChart = (key) => {
            expandedCharts[key] = !expandedCharts[key];
            if (expandedCharts[key]) {
                nextTick(() => drawChart(key));
            }
        };

        // 绘制网速历史图表
        const drawChart = (key) => {
            const canvasId = 'chart-' + key.replaceAll('.', '-');
            const canvas = document.getElementById(canvasId);
            if (!canvas) return;
            const ctx = canvas.getContext('2d');
            const history = speedHistoryMap[key];
            const txArr = history ? history.tx : [];
            const rxArr = history ? history.rx : [];

            // 高清适配
            const dpr = window.devicePixelRatio || 1;
            const rect = canvas.getBoundingClientRect();
            canvas.width = rect.width * dpr;
            canvas.height = rect.height * dpr;
            ctx.scale(dpr, dpr);
            const w = rect.width;
            const h = rect.height;

            const padTop = 8, padBottom = 4, padLeft = 0, padRight = 0;
            const chartW = w - padLeft - padRight;
            const chartH = h - padTop - padBottom;

            // 背景
            ctx.fillStyle = '#0c1222';
            ctx.fillRect(0, 0, w, h);

            // 计算Y轴最大值
            const allValues = [...txArr, ...rxArr];
            let maxVal = allValues.length > 0 ? Math.max(...allValues) : 0;
            if (maxVal < 1024) maxVal = 1024;
            const niceMax = niceNumber(maxVal);

            // 更新最大值标签
            const maxLabel = document.getElementById('chart-max-' + key.replaceAll('.', '-'));
            if (maxLabel) maxLabel.textContent = '峰值: ' + formatSpeed(niceMax);

            // 网格线
            const gridLines = 4;
            ctx.strokeStyle = 'rgba(71, 85, 105, 0.3)';
            ctx.lineWidth = 1;
            for (let i = 0; i <= gridLines; i++) {
                const y = padTop + (chartH / gridLines) * i;
                ctx.beginPath();
                ctx.moveTo(padLeft, y);
                ctx.lineTo(padLeft + chartW, y);
                ctx.stroke();
            }
            const vLines = 6;
            for (let i = 0; i <= vLines; i++) {
                const x = padLeft + (chartW / vLines) * i;
                ctx.beginPath();
                ctx.moveTo(x, padTop);
                ctx.lineTo(x, padTop + chartH);
                ctx.stroke();
            }

            // 绘制曲线
            const drawLine = (data, strokeColor, fillColor) => {
                if (data.length < 2) return;
                const step = chartW / (HISTORY_SIZE - 1);
                const offset = HISTORY_SIZE - data.length;

                // 填充区域
                ctx.beginPath();
                ctx.moveTo(padLeft + offset * step, padTop + chartH);
                for (let i = 0; i < data.length; i++) {
                    const x = padLeft + (offset + i) * step;
                    const y = padTop + chartH - (data[i] / niceMax) * chartH;
                    ctx.lineTo(x, y);
                }
                ctx.lineTo(padLeft + (offset + data.length - 1) * step, padTop + chartH);
                ctx.closePath();
                ctx.fillStyle = fillColor;
                ctx.fill();

                // 线条
                ctx.beginPath();
                for (let i = 0; i < data.length; i++) {
                    const x = padLeft + (offset + i) * step;
                    const y = padTop + chartH - (data[i] / niceMax) * chartH;
                    if (i === 0) ctx.moveTo(x, y);
                    else ctx.lineTo(x, y);
                }
                ctx.strokeStyle = strokeColor;
                ctx.lineWidth = 1.5;
                ctx.stroke();
            };

            drawLine(rxArr, '#60a5fa', 'rgba(96, 165, 250, 0.15)');
            drawLine(txArr, '#4ade80', 'rgba(74, 222, 128, 0.15)');
        };

        // 将数值取整到适合的刻度
        const niceNumber = (val) => {
            const units = [
                1024,              // 1KB
                10 * 1024,         // 10KB
                100 * 1024,        // 100KB
                1024 * 1024,       // 1MB
                10 * 1024 * 1024,  // 10MB
                100 * 1024 * 1024, // 100MB
                1024 * 1024 * 1024,// 1GB
            ];
            for (const u of units) {
                if (val <= u) return u;
            }
            return Math.ceil(val / (1024 * 1024 * 1024)) * 1024 * 1024 * 1024;
        };

        // 格式化字节数为人类可读格式
        const formatBytes = (bytes) => {
            if (bytes === 0 || bytes === null || bytes === undefined) return '0 B';
            const k = 1024;
            const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        };

        // 格式化网速（字节/秒）
        const formatSpeed = (bytesPerSecond) => {
            if (bytesPerSecond === 0 || bytesPerSecond === null || bytesPerSecond === undefined) return '0 B/s';
            const k = 1024;
            const sizes = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
            const i = Math.floor(Math.log(bytesPerSecond) / Math.log(k));
            return parseFloat((bytesPerSecond / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        };

        onMounted(() => {
            applyTheme();
            window.addEventListener('hashchange', handleRouteChange);
            if (isLoggedIn.value) {
                handleRouteChange();
            }
        });

        onUnmounted(() => {
            stopDeviceRefresh();
            window.removeEventListener('hashchange', handleRouteChange);
        });

        return {
            isLoggedIn,
            theme,
            isDarkTheme,
            toggleTheme,
            loginForm,
            handleLogin,
            logout,
            username,
            currentView,
            serverStatus,
            statusListeners,
            fetchStatus,
            loading,
            errorMsg,
            modalErrorMsg,
            networks,
            networkSearch,
            filteredNetworks,
            selectNetwork,
            devices,
            deviceSearch,
            filteredDevices,
            mergedDevices,
            toggleExpand,
            currentNetworkCode,
            formatBytes,
            formatSpeed,
            formatDuration,
            formatSource,
            getSourceColor,
            // 网速历史图表
            expandedCharts,
            toggleChart,
            // 网络管理
            showNetworkModal,
            isEditMode,
            networkForm,
            openAddNetworkModal,
            openEditNetworkModal,
            closeNetworkModal,
            submitNetworkForm,
            // 删除确认
            showConfirmModal,
            confirmMessage,
            confirmDeleteNetwork,
            confirmDeleteDevice,
            closeConfirmModal,
            executeDelete,
            fetchNetworks,
            // 服务器列表
            peerServers,
            fetchPeerServers,
            // 路由导航
            navigateToStatus,
            navigateToNetworks,
            navigateToServers,
            navigateToWireGuard,
            // 服务器管理
            showAddServerModal,
            serverForm,
            openAddServerModal,
            closeAddServerModal,
            submitAddServer,
            confirmDeleteServer,
            // WireGuard 管理
            wireguardNetworkCode,
            wireguardPeers,
            wireguardIpDrafts,
            wireguardIpMap,
            wireguardPeerKey,
            wireguardPeerRowClass,
            showWireGuardPeerModal,
            wireguardPeerForm,
            wireguardEditingPeer,
            wireguardPeerMode,
            generatedWireGuardPeer,
            wireguardGeneratedPeerNew,
            wireguardPrivateKeyCopied,
            wireguardPrivateKeySaved,
            wireguardConfigCopied,
            wireguardConfigDownloaded,
            wireguardQrCanvas,
            generatedWireGuardConfig,
            generatedWireGuardConfigFilename,
            fetchWireGuardData,
            openWireGuardPeerModal,
            openWireGuardProfileModal,
            openStoredWireGuardConfig,
            closeWireGuardPeerModal,
            addWireGuardRoute,
            removeWireGuardRoute,
            submitWireGuardPeer,
            copyGeneratedWireGuardPrivateKey,
            copyGeneratedWireGuardConfig,
            downloadGeneratedWireGuardConfig,
            finishGeneratedWireGuardPeer,
            discardGeneratedWireGuardPeer,
            setWireGuardPeerEnabled,
            reserveWireGuardPeerIp,
            releaseWireGuardPeerIp,
            confirmDeleteWireGuardPeer,
            formatTimestamp,
            wireguardStatusLabel,
            wireguardStatusClass
        };
    }
};

appOptions.render = (function compileTemplate(Vue) {
const _Vue = Vue
const { createVNode: _createVNode, createElementVNode: _createElementVNode, createCommentVNode: _createCommentVNode, createTextVNode: _createTextVNode } = _Vue

const _hoisted_1 = { class: "bg-white shadow-sm mb-6" }
const _hoisted_2 = { class: "max-w-[1600px] mx-auto px-4 sm:px-6 lg:px-8" }
const _hoisted_3 = { class: "flex flex-col lg:flex-row lg:justify-between min-h-16 py-3 lg:py-0 gap-3" }
const _hoisted_4 = { class: "flex flex-col sm:flex-row sm:items-center gap-3 sm:gap-6" }
const _hoisted_5 = {
  key: 0,
  class: "flex flex-wrap gap-x-4 gap-y-2"
}
const _hoisted_6 = ["onClick"]
const _hoisted_7 = ["onClick"]
const _hoisted_8 = ["onClick"]
const _hoisted_9 = ["onClick"]
const _hoisted_10 = { class: "flex items-center self-end lg:self-auto gap-3" }
const _hoisted_11 = ["onClick", "aria-pressed", "aria-label", "title"]
const _hoisted_12 = {
  key: 0,
  class: "flex items-center"
}
const _hoisted_13 = { class: "mr-4 text-sm text-gray-600" }
const _hoisted_14 = ["onClick"]
const _hoisted_15 = { class: "max-w-[1600px] mx-auto px-4 sm:px-6 lg:px-8" }
const _hoisted_16 = {
  key: "login",
  class: "flex justify-center items-center h-[60vh]"
}
const _hoisted_17 = { class: "bg-white p-8 rounded-lg shadow-lg w-full max-w-md" }
const _hoisted_18 = ["onSubmit"]
const _hoisted_19 = { class: "mb-4" }
const _hoisted_20 = ["onUpdate:modelValue"]
const _hoisted_21 = { class: "mb-6" }
const _hoisted_22 = ["onUpdate:modelValue"]
const _hoisted_23 = ["disabled"]
const _hoisted_24 = {
  key: 0,
  class: "text-red-500 text-xs italic mt-4 text-center"
}
const _hoisted_25 = { key: "status" }
const _hoisted_26 = { class: "flex flex-col md:flex-row justify-between items-center mb-6" }
const _hoisted_27 = ["onClick", "disabled"]
const _hoisted_28 = {
  key: 0,
  class: "mb-6 rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700"
}
const _hoisted_29 = {
  key: 1,
  class: "text-center py-10"
}
const _hoisted_30 = {
  key: 2,
  class: "space-y-6"
}
const _hoisted_31 = { class: "grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4" }
const _hoisted_32 = { class: "bg-white rounded-lg shadow p-5 border-l-4 border-blue-500" }
const _hoisted_33 = { class: "text-xl font-bold mt-2" }
const _hoisted_34 = { class: "bg-white rounded-lg shadow p-5 border-l-4 border-green-500" }
const _hoisted_35 = { class: "text-xl font-bold mt-2" }
const _hoisted_36 = { class: "text-xl font-bold mt-2" }
const _hoisted_37 = { class: "text-xl font-bold mt-2" }
const _hoisted_38 = { class: "grid grid-cols-1 xl:grid-cols-2 gap-6" }
const _hoisted_39 = { class: "bg-white rounded-lg shadow p-6" }
const _hoisted_40 = { class: "space-y-3 text-sm" }
const _hoisted_41 = { class: "text-gray-500" }
const _hoisted_42 = { class: "font-mono text-right break-all" }
const _hoisted_43 = { class: "bg-white rounded-lg shadow p-6" }
const _hoisted_44 = { class: "grid grid-cols-2 gap-4 text-sm" }
const _hoisted_45 = { class: "rounded-lg bg-blue-50 p-4" }
const _hoisted_46 = { class: "text-2xl font-bold text-blue-700 mt-1" }
const _hoisted_47 = { class: "rounded-lg bg-green-50 p-4" }
const _hoisted_48 = { class: "text-2xl font-bold text-green-700 mt-1" }
const _hoisted_49 = { class: "rounded-lg bg-purple-50 p-4" }
const _hoisted_50 = { class: "text-2xl font-bold text-purple-700 mt-1" }
const _hoisted_51 = { class: "rounded-lg bg-cyan-50 p-4" }
const _hoisted_52 = { class: "text-2xl font-bold text-cyan-700 mt-1" }
const _hoisted_53 = { class: "mt-4 text-xs text-gray-500" }
const _hoisted_54 = { key: "networks" }
const _hoisted_55 = { class: "flex flex-col md:flex-row justify-between items-center mb-6" }
const _hoisted_56 = { class: "flex items-center space-x-4" }
const _hoisted_57 = { class: "relative w-full md:w-64" }
const _hoisted_58 = ["onUpdate:modelValue"]
const _hoisted_59 = ["onClick"]
const _hoisted_60 = {
  key: 0,
  class: "text-center py-10"
}
const _hoisted_61 = {
  key: 1,
  class: "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6"
}
const _hoisted_62 = { class: "flex justify-between items-start" }
const _hoisted_63 = ["onClick"]
const _hoisted_64 = { class: "text-lg font-bold text-gray-800 group-hover:text-blue-600" }
const _hoisted_65 = { class: "text-gray-500 text-sm mt-1" }
const _hoisted_66 = { class: "text-gray-400 text-xs mt-1" }
const _hoisted_67 = { class: "text-gray-400 text-xs mt-1" }
const _hoisted_68 = { class: "flex flex-col items-end" }
const _hoisted_69 = { class: "bg-blue-50 px-3 py-1 rounded-full mb-2" }
const _hoisted_70 = { class: "text-blue-600 font-bold text-sm" }
const _hoisted_71 = { class: "text-gray-400 text-xs" }
const _hoisted_72 = { class: "flex space-x-2" }
const _hoisted_73 = ["onClick"]
const _hoisted_74 = ["onClick"]
const _hoisted_75 = ["onClick"]
const _hoisted_76 = {
  key: 2,
  class: "text-center text-gray-500 py-10"
}
const _hoisted_77 = { key: "devices" }
const _hoisted_78 = { class: "flex flex-col md:flex-row justify-between items-center mb-6" }
const _hoisted_79 = { class: "flex items-center mb-4 md:mb-0" }
const _hoisted_80 = ["onClick"]
const _hoisted_81 = { class: "text-sm text-gray-500" }
const _hoisted_82 = { class: "relative w-full md:w-64" }
const _hoisted_83 = ["onUpdate:modelValue"]
const _hoisted_84 = {
  key: 0,
  class: "text-center py-10"
}
const _hoisted_85 = {
  key: 1,
  class: "bg-white shadow rounded-lg overflow-x-auto"
}
const _hoisted_86 = { class: "min-w-full divide-y divide-gray-200" }
const _hoisted_87 = { class: "bg-white divide-y divide-gray-200" }
const _hoisted_88 = { class: "px-4 py-4 whitespace-nowrap" }
const _hoisted_89 = { class: "flex items-center space-x-1" }
const _hoisted_90 = ["onClick"]
const _hoisted_91 = ["onClick"]
const _hoisted_92 = { class: "px-6 py-4 whitespace-nowrap" }
const _hoisted_93 = {
  key: 0,
  class: "px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-green-800"
}
const _hoisted_94 = {
  key: 1,
  class: "px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-blue-100 text-blue-800"
}
const _hoisted_95 = {
  key: 2,
  class: "px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-red-100 text-red-800"
}
const _hoisted_96 = { class: "px-6 py-4 whitespace-nowrap" }
const _hoisted_97 = { class: "text-sm font-medium text-gray-900" }
const _hoisted_98 = { class: "text-sm text-gray-500" }
const _hoisted_99 = {
  key: 0,
  class: "text-xs text-blue-500 mt-1"
}
const _hoisted_100 = { class: "px-6 py-4 whitespace-nowrap text-sm text-gray-500" }
const _hoisted_101 = { class: "px-6 py-4 whitespace-nowrap text-sm text-gray-500" }
const _hoisted_102 = { class: "px-6 py-4 whitespace-nowrap text-sm" }
const _hoisted_103 = {
  key: 1,
  class: "text-gray-400"
}
const _hoisted_104 = { class: "px-3 py-4 whitespace-nowrap text-sm text-gray-700" }
const _hoisted_105 = { class: "text-green-700" }
const _hoisted_106 = { class: "text-blue-700" }
const _hoisted_107 = { class: "px-3 py-4 whitespace-nowrap text-sm" }
const _hoisted_108 = { class: "text-green-600" }
const _hoisted_109 = { class: "text-blue-600" }
const _hoisted_110 = { class: "px-3 py-4 whitespace-nowrap text-sm text-gray-500" }
const _hoisted_111 = {
  key: 0,
  class: "text-xs text-red-400"
}
const _hoisted_112 = { class: "px-6 py-4 whitespace-nowrap text-sm" }
const _hoisted_113 = ["onClick"]
const _hoisted_114 = ["title"]
const _hoisted_115 = { key: 0 }
const _hoisted_116 = {
  colspan: "10",
  class: "p-0"
}
const _hoisted_117 = { class: "px-4 py-3 bg-gray-900" }
const _hoisted_118 = { class: "flex items-center space-x-4 mb-2 text-xs text-gray-400" }
const _hoisted_119 = ["id"]
const _hoisted_120 = ["id"]
const _hoisted_121 = { class: "px-6 py-3 whitespace-nowrap" }
const _hoisted_122 = {
  key: 0,
  class: "px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-green-800"
}
const _hoisted_123 = {
  key: 1,
  class: "px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-blue-100 text-blue-800"
}
const _hoisted_124 = {
  key: 2,
  class: "px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-red-100 text-red-800"
}
const _hoisted_125 = { class: "px-6 py-3 whitespace-nowrap" }
const _hoisted_126 = { class: "text-xs text-gray-600" }
const _hoisted_127 = {
  key: 0,
  class: "text-blue-600 font-medium"
}
const _hoisted_128 = {
  key: 1,
  class: "text-green-600 font-medium"
}
const _hoisted_129 = { class: "px-6 py-3 whitespace-nowrap text-xs text-gray-500" }
const _hoisted_130 = { class: "px-6 py-3 whitespace-nowrap text-xs" }
const _hoisted_131 = {
  key: 1,
  class: "text-gray-400"
}
const _hoisted_132 = { class: "px-3 py-3 whitespace-nowrap text-xs text-gray-600" }
const _hoisted_133 = { class: "text-green-700" }
const _hoisted_134 = { class: "text-blue-700" }
const _hoisted_135 = { class: "px-3 py-3 whitespace-nowrap text-xs" }
const _hoisted_136 = { class: "text-green-600" }
const _hoisted_137 = { class: "text-blue-600" }
const _hoisted_138 = { class: "px-3 py-3 whitespace-nowrap text-xs text-gray-500" }
const _hoisted_139 = { key: 0 }
const _hoisted_140 = { key: "servers" }
const _hoisted_141 = { class: "flex justify-between items-center mb-6" }
const _hoisted_142 = ["onClick"]
const _hoisted_143 = {
  key: 0,
  class: "text-center py-10"
}
const _hoisted_144 = {
  key: 1,
  class: "space-y-6"
}
const _hoisted_145 = { class: "bg-white rounded-lg shadow p-6" }
const _hoisted_146 = { class: "text-lg font-bold text-gray-800 mb-4 flex items-center" }
const _hoisted_147 = { class: "ml-2 text-sm font-normal text-gray-500" }
const _hoisted_148 = {
  key: 0,
  class: "text-center text-gray-500 py-8"
}
const _hoisted_149 = {
  key: 1,
  class: "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
}
const _hoisted_150 = { class: "flex items-start justify-between mb-2" }
const _hoisted_151 = { class: "flex-1" }
const _hoisted_152 = { class: "font-semibold text-gray-800 flex items-center" }
const _hoisted_153 = { class: "flex items-center space-x-2" }
const _hoisted_154 = {
  key: 0,
  class: "px-2 py-1 text-xs font-semibold rounded-full bg-green-100 text-green-800"
}
const _hoisted_155 = {
  key: 1,
  class: "px-2 py-1 text-xs font-semibold rounded-full bg-gray-200 text-gray-600"
}
const _hoisted_156 = ["onClick"]
const _hoisted_157 = { class: "text-sm text-gray-600 mt-2" }
const _hoisted_158 = { class: "font-medium" }
const _hoisted_159 = { class: "bg-white rounded-lg shadow p-6" }
const _hoisted_160 = { class: "text-lg font-bold text-gray-800 mb-4 flex items-center" }
const _hoisted_161 = { class: "ml-2 text-sm font-normal text-gray-500" }
const _hoisted_162 = {
  key: 0,
  class: "text-center text-gray-500 py-8"
}
const _hoisted_163 = {
  key: 1,
  class: "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
}
const _hoisted_164 = { class: "flex items-start justify-between mb-2" }
const _hoisted_165 = { class: "flex-1" }
const _hoisted_166 = { class: "font-semibold text-gray-800 flex items-center" }
const _hoisted_167 = {
  key: 0,
  class: "px-2 py-1 text-xs font-semibold rounded-full bg-green-100 text-green-800"
}
const _hoisted_168 = {
  key: 1,
  class: "px-2 py-1 text-xs font-semibold rounded-full bg-gray-200 text-gray-600"
}
const _hoisted_169 = { class: "text-sm text-gray-600 mt-2" }
const _hoisted_170 = { class: "font-medium" }
const _hoisted_171 = { key: "wireguard" }
const _hoisted_172 = { class: "flex flex-col xl:flex-row xl:justify-between xl:items-end gap-4 mb-6" }
const _hoisted_173 = { class: "flex flex-col sm:flex-row gap-3 w-full xl:w-auto" }
const _hoisted_174 = { class: "flex flex-col text-sm text-gray-600 min-w-64" }
const _hoisted_175 = ["onUpdate:modelValue", "onChange"]
const _hoisted_176 = ["value"]
const _hoisted_177 = ["onClick", "disabled"]
const _hoisted_178 = {
  key: 0,
  class: "mb-6 rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700"
}
const _hoisted_179 = {
  key: 1,
  class: "bg-white rounded-lg shadow p-10 text-center text-gray-500"
}
const _hoisted_180 = {
  key: 2,
  class: "text-center py-10"
}
const _hoisted_181 = {
  key: 3,
  class: "bg-white shadow rounded-lg overflow-x-auto"
}
const _hoisted_182 = { class: "px-6 py-4 border-b flex justify-between items-center" }
const _hoisted_183 = { class: "text-sm text-gray-500" }
const _hoisted_184 = { class: "min-w-full divide-y divide-gray-200" }
const _hoisted_185 = { class: "bg-white divide-y divide-gray-200" }
const _hoisted_186 = { class: "px-4 py-4 whitespace-nowrap font-medium text-gray-900" }
const _hoisted_187 = { class: "px-4 py-4 whitespace-nowrap text-sm text-gray-600" }
const _hoisted_188 = { class: "px-4 py-4" }
const _hoisted_189 = ["title"]
const _hoisted_190 = { class: "px-4 py-4 whitespace-nowrap" }
const _hoisted_191 = { class: "px-4 py-4" }
const _hoisted_192 = { class: "flex items-center gap-2" }
const _hoisted_193 = ["onUpdate:modelValue"]
const _hoisted_194 = ["onClick", "disabled"]
const _hoisted_195 = ["onClick", "disabled"]
const _hoisted_196 = { class: "px-4 py-4 text-xs text-gray-600" }
const _hoisted_197 = {
  key: 0,
  class: "text-gray-400"
}
const _hoisted_198 = { class: "mt-1" }
const _hoisted_199 = { class: "mt-1" }
const _hoisted_200 = { class: "mt-1" }
const _hoisted_201 = { class: "px-4 py-4 whitespace-nowrap text-sm text-gray-500" }
const _hoisted_202 = { class: "px-4 py-4 whitespace-nowrap text-right text-sm" }
const _hoisted_203 = ["onClick", "disabled"]
const _hoisted_204 = ["onClick", "disabled"]
const _hoisted_205 = ["onClick", "disabled"]
const _hoisted_206 = ["onClick", "disabled"]
const _hoisted_207 = { key: 0 }
const _hoisted_208 = {
  colspan: "8",
  class: "px-6 py-10 text-center text-gray-500"
}
const _hoisted_209 = ["onClick"]
const _hoisted_210 = { class: "bg-white rounded-lg shadow-xl w-full max-w-md mx-4 p-6" }
const _hoisted_211 = { class: "text-xl font-bold mb-4" }
const _hoisted_212 = ["onSubmit"]
const _hoisted_213 = { class: "mb-4" }
const _hoisted_214 = ["onUpdate:modelValue", "disabled"]
const _hoisted_215 = { class: "mb-4" }
const _hoisted_216 = ["onUpdate:modelValue"]
const _hoisted_217 = { class: "mb-4" }
const _hoisted_218 = ["onUpdate:modelValue"]
const _hoisted_219 = { class: "mb-6" }
const _hoisted_220 = ["onUpdate:modelValue"]
const _hoisted_221 = { class: "flex justify-end space-x-3" }
const _hoisted_222 = ["onClick"]
const _hoisted_223 = ["disabled"]
const _hoisted_224 = {
  key: 0,
  class: "text-red-500 text-sm mt-4"
}
const _hoisted_225 = ["onClick"]
const _hoisted_226 = { class: "bg-white rounded-lg shadow-xl w-full max-w-sm mx-4 p-6" }
const _hoisted_227 = { class: "text-gray-600 mb-6" }
const _hoisted_228 = { class: "flex justify-end space-x-3" }
const _hoisted_229 = ["onClick"]
const _hoisted_230 = ["onClick", "disabled"]
const _hoisted_231 = {
  key: 0,
  class: "text-red-500 text-sm mt-4"
}
const _hoisted_232 = ["onClick"]
const _hoisted_233 = { class: "bg-white rounded-lg shadow-xl w-full max-w-md mx-4 p-6" }
const _hoisted_234 = ["onSubmit"]
const _hoisted_235 = { class: "mb-4" }
const _hoisted_236 = ["onUpdate:modelValue"]
const _hoisted_237 = { class: "flex justify-end space-x-3" }
const _hoisted_238 = ["onClick"]
const _hoisted_239 = ["disabled"]
const _hoisted_240 = {
  key: 0,
  class: "text-red-500 text-sm mt-4"
}
const _hoisted_241 = {
  key: 3,
  class: "modal-mask"
}
const _hoisted_242 = { class: "bg-white rounded-lg shadow-xl w-full max-w-2xl mx-4 p-6 max-h-screen overflow-y-auto" }
const _hoisted_243 = { class: "text-xl font-bold mb-4" }
const _hoisted_244 = { key: 0 }
const _hoisted_245 = {
  key: 0,
  class: "rounded border border-amber-300 bg-amber-50 p-4 mb-4 text-amber-900"
}
const _hoisted_246 = { class: "grid grid-cols-1 sm:grid-cols-3 gap-3 mb-4 text-sm" }
const _hoisted_247 = { class: "rounded bg-gray-50 p-3" }
const _hoisted_248 = { class: "font-medium break-all" }
const _hoisted_249 = { class: "rounded bg-gray-50 p-3" }
const _hoisted_250 = { class: "font-medium break-all" }
const _hoisted_251 = { class: "rounded bg-gray-50 p-3" }
const _hoisted_252 = { class: "font-medium" }
const _hoisted_253 = { class: "mb-4" }
const _hoisted_254 = ["value"]
const _hoisted_255 = { class: "flex items-center justify-between mt-2 gap-3" }
const _hoisted_256 = ["onClick"]
const _hoisted_257 = { class: "grid grid-cols-1 md:grid-cols-3 gap-4 mb-4" }
const _hoisted_258 = { class: "md:col-span-2" }
const _hoisted_259 = { class: "flex items-center justify-between gap-3 mb-2" }
const _hoisted_260 = { class: "text-xs text-gray-500 break-all" }
const _hoisted_261 = ["value"]
const _hoisted_262 = { class: "flex flex-wrap gap-2 mt-2" }
const _hoisted_263 = ["onClick"]
const _hoisted_264 = ["onClick"]
const _hoisted_265 = { class: "flex flex-col items-center rounded border border-gray-200 bg-white p-3" }
const _hoisted_266 = {
  ref: "wireguardQrCanvas",
  class: "max-w-full"
}
const _hoisted_267 = { class: "mb-4 rounded border border-gray-200 p-3 text-sm" }
const _hoisted_268 = { class: "mt-3 space-y-3" }
const _hoisted_269 = { class: "block break-all rounded bg-gray-50 p-2" }
const _hoisted_270 = { class: "block break-all rounded bg-gray-50 p-2" }
const _hoisted_271 = { class: "block break-all rounded bg-gray-50 p-2" }
const _hoisted_272 = {
  key: 1,
  class: "flex items-start rounded border border-gray-200 p-3 mb-4 text-sm text-gray-700"
}
const _hoisted_273 = ["onUpdate:modelValue"]
const _hoisted_274 = { class: "flex flex-col-reverse sm:flex-row sm:justify-between gap-3" }
const _hoisted_275 = ["onClick", "disabled"]
const _hoisted_276 = ["onClick", "disabled"]
const _hoisted_277 = ["onSubmit"]
const _hoisted_278 = { class: "mb-4" }
const _hoisted_279 = ["onUpdate:modelValue"]
const _hoisted_280 = ["value"]
const _hoisted_281 = ["value"]
const _hoisted_282 = { class: "mb-4" }
const _hoisted_283 = ["onUpdate:modelValue", "disabled"]
const _hoisted_284 = {
  key: 0,
  class: "mb-4"
}
const _hoisted_285 = { class: "grid grid-cols-1 sm:grid-cols-2 gap-3" }
const _hoisted_286 = ["onUpdate:modelValue"]
const _hoisted_287 = ["onUpdate:modelValue"]
const _hoisted_288 = {
  key: 1,
  class: "mb-4"
}
const _hoisted_289 = ["onUpdate:modelValue"]
const _hoisted_290 = { class: "mb-4 rounded border border-gray-200 p-3" }
const _hoisted_291 = { class: "flex items-center text-sm text-gray-700" }
const _hoisted_292 = ["onUpdate:modelValue"]
const _hoisted_293 = ["onUpdate:modelValue"]
const _hoisted_294 = { class: "mb-4" }
const _hoisted_295 = ["onUpdate:modelValue"]
const _hoisted_296 = { class: "mb-4" }
const _hoisted_297 = { class: "space-y-3" }
const _hoisted_298 = { class: "flex-1 min-w-0" }
const _hoisted_299 = { class: "flex items-center" }
const _hoisted_300 = ["onUpdate:modelValue"]
const _hoisted_301 = ["onUpdate:modelValue"]
const _hoisted_302 = ["value"]
const _hoisted_303 = { class: "flex-1 min-w-0" }
const _hoisted_304 = ["onUpdate:modelValue"]
const _hoisted_305 = ["onClick"]
const _hoisted_306 = ["onClick"]
const _hoisted_307 = {
  key: 2,
  class: "flex items-center mb-6 text-sm text-gray-700"
}
const _hoisted_308 = ["onUpdate:modelValue"]
const _hoisted_309 = { class: "flex justify-end space-x-3" }
const _hoisted_310 = ["onClick"]
const _hoisted_311 = ["disabled"]
const _hoisted_312 = {
  key: 2,
  class: "text-red-500 text-sm mt-4"
}

return function render(_ctx, _cache) {
  with (_ctx) {
    const { createElementVNode: _createElementVNode, createTextVNode: _createTextVNode, normalizeClass: _normalizeClass, openBlock: _openBlock, createElementBlock: _createElementBlock, createCommentVNode: _createCommentVNode, toDisplayString: _toDisplayString, vModelText: _vModelText, withDirectives: _withDirectives, withModifiers: _withModifiers, renderList: _renderList, Fragment: _Fragment, vModelSelect: _vModelSelect, Transition: _Transition, withCtx: _withCtx, createVNode: _createVNode, vModelCheckbox: _vModelCheckbox, vModelRadio: _vModelRadio } = _Vue

    return (_openBlock(), _createElementBlock(_Fragment, null, [
      _createElementVNode("nav", _hoisted_1, [
        _createElementVNode("div", _hoisted_2, [
          _createElementVNode("div", _hoisted_3, [
            _createElementVNode("div", _hoisted_4, [
              _cache[4] || (_cache[4] = _createElementVNode("div", { class: "flex items-center" }, [
                _createElementVNode("i", { class: "fa-solid fa-network-wired text-blue-600 text-xl mr-2" }),
                _createElementVNode("span", { class: "font-bold text-xl" }, "VNTS Control Center")
              ], -1 /* CACHED */)),
              isLoggedIn
                ? (_openBlock(), _createElementBlock("nav", _hoisted_5, [
                    _createElementVNode("button", {
                      onClick: navigateToStatus,
                      class: _normalizeClass([currentView === 'status' ? 'text-blue-600 font-semibold' : 'text-gray-600 hover:text-blue-600', "text-sm transition"])
                    }, _cache[0] || (_cache[0] = [
                      _createElementVNode("i", { class: "fa-solid fa-gauge-high mr-1" }, null, -1 /* CACHED */),
                      _createTextVNode("运行概览 ")
                    ]), 10 /* CLASS, PROPS */, _hoisted_6),
                    _createElementVNode("button", {
                      onClick: navigateToNetworks,
                      class: _normalizeClass([currentView === 'networks' ? 'text-blue-600 font-semibold' : 'text-gray-600 hover:text-blue-600', "text-sm transition"])
                    }, _cache[1] || (_cache[1] = [
                      _createElementVNode("i", { class: "fa-solid fa-network-wired mr-1" }, null, -1 /* CACHED */),
                      _createTextVNode("网络管理 ")
                    ]), 10 /* CLASS, PROPS */, _hoisted_7),
                    _createElementVNode("button", {
                      onClick: navigateToServers,
                      class: _normalizeClass([currentView === 'servers' ? 'text-blue-600 font-semibold' : 'text-gray-600 hover:text-blue-600', "text-sm transition"])
                    }, _cache[2] || (_cache[2] = [
                      _createElementVNode("i", { class: "fa-solid fa-server mr-1" }, null, -1 /* CACHED */),
                      _createTextVNode("服务器列表 ")
                    ]), 10 /* CLASS, PROPS */, _hoisted_8),
                    _createElementVNode("button", {
                      onClick: navigateToWireGuard,
                      class: _normalizeClass([currentView === 'wireguard' ? 'text-blue-600 font-semibold' : 'text-gray-600 hover:text-blue-600', "text-sm transition"])
                    }, _cache[3] || (_cache[3] = [
                      _createElementVNode("i", { class: "fa-solid fa-shield-halved mr-1" }, null, -1 /* CACHED */),
                      _createTextVNode("WireGuard ")
                    ]), 10 /* CLASS, PROPS */, _hoisted_9)
                  ]))
                : _createCommentVNode("v-if", true)
            ]),
            _createElementVNode("div", _hoisted_10, [
              _createElementVNode("button", {
                type: "button",
                onClick: toggleTheme,
                class: "theme-toggle",
                "aria-pressed": isDarkTheme,
                "aria-label": isDarkTheme ? '切换为浅色主题' : '切换为深色主题',
                title: isDarkTheme ? '切换为浅色主题' : '切换为深色主题'
              }, [
                _createElementVNode("i", {
                  class: _normalizeClass(["fa-solid", isDarkTheme ? 'fa-sun' : 'fa-moon'])
                }, null, 2 /* CLASS */)
              ], 8 /* PROPS */, _hoisted_11),
              isLoggedIn
                ? (_openBlock(), _createElementBlock("div", _hoisted_12, [
                    _createElementVNode("span", _hoisted_13, [
                      _cache[5] || (_cache[5] = _createElementVNode("i", { class: "fa-solid fa-user mr-1" }, null, -1 /* CACHED */)),
                      _createTextVNode(" " + _toDisplayString(username || 'Admin'), 1 /* TEXT */)
                    ]),
                    _createElementVNode("button", {
                      onClick: logout,
                      class: "text-sm text-red-500 hover:text-red-700 font-medium"
                    }, "退出登录", 8 /* PROPS */, _hoisted_14)
                  ]))
                : _createCommentVNode("v-if", true)
            ])
          ])
        ])
      ]),
      _createElementVNode("main", _hoisted_15, [
        _createVNode(_Transition, {
          name: "fade",
          mode: "out-in"
        }, {
          default: _withCtx(() => [
            (!isLoggedIn)
              ? (_openBlock(), _createElementBlock("div", _hoisted_16, [
                  _createElementVNode("div", _hoisted_17, [
                    _cache[8] || (_cache[8] = _createElementVNode("h2", { class: "text-2xl font-bold mb-6 text-center text-gray-700" }, "请登录", -1 /* CACHED */)),
                    _createElementVNode("form", {
                      onSubmit: _withModifiers(handleLogin, ["prevent"])
                    }, [
                      _createElementVNode("div", _hoisted_19, [
                        _cache[6] || (_cache[6] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "用户名", -1 /* CACHED */)),
                        _withDirectives(_createElementVNode("input", {
                          "onUpdate:modelValue": $event => ((loginForm.username) = $event),
                          type: "text",
                          class: "shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-blue-500",
                          required: ""
                        }, null, 8 /* PROPS */, _hoisted_20), [
                          [_vModelText, loginForm.username]
                        ])
                      ]),
                      _createElementVNode("div", _hoisted_21, [
                        _cache[7] || (_cache[7] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "密码", -1 /* CACHED */)),
                        _withDirectives(_createElementVNode("input", {
                          "onUpdate:modelValue": $event => ((loginForm.password) = $event),
                          type: "password",
                          class: "shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 mb-3 leading-tight focus:outline-none focus:ring-2 focus:ring-blue-500",
                          required: ""
                        }, null, 8 /* PROPS */, _hoisted_22), [
                          [_vModelText, loginForm.password]
                        ])
                      ]),
                      _createElementVNode("button", {
                        disabled: loading,
                        type: "submit",
                        class: "w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded focus:outline-none focus:shadow-outline transition duration-200"
                      }, _toDisplayString(loading ? '登录中...' : '登 录'), 9 /* TEXT, PROPS */, _hoisted_23),
                      errorMsg
                        ? (_openBlock(), _createElementBlock("p", _hoisted_24, _toDisplayString(errorMsg), 1 /* TEXT */))
                        : _createCommentVNode("v-if", true)
                    ], 40 /* PROPS, NEED_HYDRATION */, _hoisted_18)
                  ])
                ]))
              : (currentView === 'status')
                ? (_openBlock(), _createElementBlock("div", _hoisted_25, [
                    _createElementVNode("div", _hoisted_26, [
                      _cache[10] || (_cache[10] = _createElementVNode("div", null, [
                        _createElementVNode("h2", { class: "text-2xl font-bold text-gray-800" }, "运行概览"),
                        _createElementVNode("p", { class: "text-sm text-gray-500 mt-1" }, "服务端、监听器与关键运行组件的实时状态")
                      ], -1 /* CACHED */)),
                      _createElementVNode("button", {
                        onClick: fetchStatus,
                        disabled: loading,
                        class: "mt-4 md:mt-0 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-300 text-white px-4 py-2 rounded-lg font-medium transition"
                      }, [
                        _createElementVNode("i", {
                          class: _normalizeClass(["fa-solid fa-arrows-rotate mr-2", loading ? 'fa-spin' : ''])
                        }, null, 2 /* CLASS */),
                        _cache[9] || (_cache[9] = _createTextVNode("刷新状态 "))
                      ], 8 /* PROPS */, _hoisted_27)
                    ]),
                    errorMsg
                      ? (_openBlock(), _createElementBlock("div", _hoisted_28, _toDisplayString(errorMsg), 1 /* TEXT */))
                      : _createCommentVNode("v-if", true),
                    (loading && !serverStatus)
                      ? (_openBlock(), _createElementBlock("div", _hoisted_29, _cache[11] || (_cache[11] = [
                          _createElementVNode("i", { class: "fa-solid fa-spinner fa-spin text-3xl text-blue-500" }, null, -1 /* CACHED */)
                        ])))
                      : serverStatus
                        ? (_openBlock(), _createElementBlock("div", _hoisted_30, [
                            _createElementVNode("div", _hoisted_31, [
                              _createElementVNode("div", _hoisted_32, [
                                _cache[12] || (_cache[12] = _createElementVNode("p", { class: "text-sm text-gray-500" }, "服务版本", -1 /* CACHED */)),
                                _createElementVNode("p", _hoisted_33, _toDisplayString(serverStatus.version), 1 /* TEXT */)
                              ]),
                              _createElementVNode("div", _hoisted_34, [
                                _cache[13] || (_cache[13] = _createElementVNode("p", { class: "text-sm text-gray-500" }, "管理端运行时间", -1 /* CACHED */)),
                                _createElementVNode("p", _hoisted_35, _toDisplayString(formatDuration(serverStatus.uptime_seconds)), 1 /* TEXT */)
                              ]),
                              _createElementVNode("div", {
                                class: _normalizeClass(["bg-white rounded-lg shadow p-5 border-l-4", serverStatus.database.ready ? 'border-green-500' : 'border-amber-500'])
                              }, [
                                _cache[14] || (_cache[14] = _createElementVNode("p", { class: "text-sm text-gray-500" }, "持久化数据库", -1 /* CACHED */)),
                                _createElementVNode("p", _hoisted_36, _toDisplayString(serverStatus.database.persistence_enabled ? (serverStatus.database.ready ? '已就绪' : '未就绪') : '未启用'), 1 /* TEXT */)
                              ], 2 /* CLASS */),
                              _createElementVNode("div", {
                                class: _normalizeClass(["bg-white rounded-lg shadow p-5 border-l-4", serverStatus.wireguard.running ? 'border-green-500' : 'border-gray-400'])
                              }, [
                                _cache[15] || (_cache[15] = _createElementVNode("p", { class: "text-sm text-gray-500" }, "WireGuard", -1 /* CACHED */)),
                                _createElementVNode("p", _hoisted_37, _toDisplayString(serverStatus.wireguard.configured ? (serverStatus.wireguard.running ? '运行中' : '未运行') : '未配置'), 1 /* TEXT */)
                              ], 2 /* CLASS */)
                            ]),
                            _createElementVNode("div", _hoisted_38, [
                              _createElementVNode("section", _hoisted_39, [
                                _cache[16] || (_cache[16] = _createElementVNode("h3", { class: "font-bold text-lg mb-4" }, [
                                  _createElementVNode("i", { class: "fa-solid fa-tower-broadcast text-blue-500 mr-2" }),
                                  _createTextVNode("监听地址")
                                ], -1 /* CACHED */)),
                                _createElementVNode("dl", _hoisted_40, [
                                  (_openBlock(true), _createElementBlock(_Fragment, null, _renderList(statusListeners, (listener) => {
                                    return (_openBlock(), _createElementBlock("div", {
                                      key: listener.label,
                                      class: "flex justify-between gap-4 border-b border-gray-100 pb-2"
                                    }, [
                                      _createElementVNode("dt", _hoisted_41, _toDisplayString(listener.label), 1 /* TEXT */),
                                      _createElementVNode("dd", _hoisted_42, _toDisplayString(listener.value || '未启用'), 1 /* TEXT */)
                                    ]))
                                  }), 128 /* KEYED_FRAGMENT */))
                                ])
                              ]),
                              _createElementVNode("section", _hoisted_43, [
                                _cache[21] || (_cache[21] = _createElementVNode("h3", { class: "font-bold text-lg mb-4" }, [
                                  _createElementVNode("i", { class: "fa-solid fa-chart-simple text-blue-500 mr-2" }),
                                  _createTextVNode("资源统计")
                                ], -1 /* CACHED */)),
                                _createElementVNode("dl", _hoisted_44, [
                                  _createElementVNode("div", _hoisted_45, [
                                    _cache[17] || (_cache[17] = _createElementVNode("dt", { class: "text-gray-500" }, "配置网络", -1 /* CACHED */)),
                                    _createElementVNode("dd", _hoisted_46, _toDisplayString(serverStatus.networks.configured), 1 /* TEXT */)
                                  ]),
                                  _createElementVNode("div", _hoisted_47, [
                                    _cache[18] || (_cache[18] = _createElementVNode("dt", { class: "text-gray-500" }, "在线节点", -1 /* CACHED */)),
                                    _createElementVNode("dd", _hoisted_48, _toDisplayString(serverStatus.networks.online_nodes) + "/" + _toDisplayString(serverStatus.networks.total_nodes), 1 /* TEXT */)
                                  ]),
                                  _createElementVNode("div", _hoisted_49, [
                                    _cache[19] || (_cache[19] = _createElementVNode("dt", { class: "text-gray-500" }, "互联服务器", -1 /* CACHED */)),
                                    _createElementVNode("dd", _hoisted_50, _toDisplayString(serverStatus.peer_servers.connected) + "/" + _toDisplayString(serverStatus.peer_servers.total_connections), 1 /* TEXT */)
                                  ]),
                                  _createElementVNode("div", _hoisted_51, [
                                    _cache[20] || (_cache[20] = _createElementVNode("dt", { class: "text-gray-500" }, "WireGuard 活动 Peer", -1 /* CACHED */)),
                                    _createElementVNode("dd", _hoisted_52, _toDisplayString(serverStatus.wireguard.active_peers) + "/" + _toDisplayString(serverStatus.wireguard.max_active_peers), 1 /* TEXT */)
                                  ])
                                ]),
                                _createElementVNode("p", _hoisted_53, "WireGuard 监听：" + _toDisplayString(serverStatus.wireguard.listen_addr || '未启用'), 1 /* TEXT */)
                              ])
                            ])
                          ]))
                        : _createCommentVNode("v-if", true)
                  ]))
                : (currentView === 'networks')
                  ? (_openBlock(), _createElementBlock("div", _hoisted_54, [
                      _createElementVNode("div", _hoisted_55, [
                        _cache[24] || (_cache[24] = _createElementVNode("h2", { class: "text-2xl font-bold text-gray-800 mb-4 md:mb-0" }, "网络列表", -1 /* CACHED */)),
                        _createElementVNode("div", _hoisted_56, [
                          _createElementVNode("div", _hoisted_57, [
                            _cache[22] || (_cache[22] = _createElementVNode("span", { class: "absolute inset-y-0 left-0 flex items-center pl-3" }, [
                              _createElementVNode("i", { class: "fa-solid fa-magnifying-glass text-gray-400" })
                            ], -1 /* CACHED */)),
                            _withDirectives(_createElementVNode("input", {
                              "onUpdate:modelValue": $event => ((networkSearch) = $event),
                              type: "text",
                              placeholder: "搜索网络代码...",
                              class: "w-full pl-10 pr-4 py-2 rounded-lg border focus:outline-none focus:ring-2 focus:ring-blue-500"
                            }, null, 8 /* PROPS */, _hoisted_58), [
                              [_vModelText, networkSearch]
                            ])
                          ]),
                          _createElementVNode("button", {
                            onClick: openAddNetworkModal,
                            class: "bg-green-500 hover:bg-green-600 text-white px-4 py-2 rounded-lg font-medium transition flex items-center"
                          }, _cache[23] || (_cache[23] = [
                            _createElementVNode("i", { class: "fa-solid fa-plus mr-2" }, null, -1 /* CACHED */),
                            _createTextVNode("新增网络 ")
                          ]), 8 /* PROPS */, _hoisted_59)
                        ])
                      ]),
                      loading
                        ? (_openBlock(), _createElementBlock("div", _hoisted_60, _cache[25] || (_cache[25] = [
                            _createElementVNode("i", { class: "fa-solid fa-spinner fa-spin text-3xl text-blue-500" }, null, -1 /* CACHED */)
                          ])))
                        : (_openBlock(), _createElementBlock("div", _hoisted_61, [
                            (_openBlock(true), _createElementBlock(_Fragment, null, _renderList(filteredNetworks, (net) => {
                              return (_openBlock(), _createElementBlock("div", {
                                key: net.network_code,
                                class: "bg-white p-6 rounded-lg shadow hover:shadow-md transition border-l-4 border-blue-500 group"
                              }, [
                                _createElementVNode("div", _hoisted_62, [
                                  _createElementVNode("div", {
                                    class: "cursor-pointer flex-1",
                                    onClick: $event => (selectNetwork(net.network_code))
                                  }, [
                                    _createElementVNode("h3", _hoisted_64, _toDisplayString(net.network_code), 1 /* TEXT */),
                                    _createElementVNode("p", _hoisted_65, _toDisplayString(net.net), 1 /* TEXT */),
                                    _createElementVNode("p", _hoisted_66, [
                                      _cache[26] || (_cache[26] = _createElementVNode("i", { class: "fa-solid fa-server mr-1" }, null, -1 /* CACHED */)),
                                      _createTextVNode("网关: " + _toDisplayString(net.gateway), 1 /* TEXT */)
                                    ]),
                                    _createElementVNode("p", _hoisted_67, [
                                      _cache[27] || (_cache[27] = _createElementVNode("i", { class: "fa-solid fa-clock mr-1" }, null, -1 /* CACHED */)),
                                      _createTextVNode("租期: " + _toDisplayString(formatDuration(net.lease_duration)), 1 /* TEXT */)
                                    ]),
                                    _createElementVNode("p", {
                                      class: _normalizeClass(["text-xs mt-1", getSourceColor(net.source)])
                                    }, [
                                      _cache[28] || (_cache[28] = _createElementVNode("i", { class: "fa-solid fa-tag mr-1" }, null, -1 /* CACHED */)),
                                      _createTextVNode("来源: " + _toDisplayString(formatSource(net.source)), 1 /* TEXT */)
                                    ], 2 /* CLASS */)
                                  ], 8 /* PROPS */, _hoisted_63),
                                  _createElementVNode("div", _hoisted_68, [
                                    _createElementVNode("div", _hoisted_69, [
                                      _createElementVNode("span", _hoisted_70, _toDisplayString(net.online_count), 1 /* TEXT */),
                                      _createElementVNode("span", _hoisted_71, "/" + _toDisplayString(net.all_count), 1 /* TEXT */)
                                    ]),
                                    _createElementVNode("div", _hoisted_72, [
                                      _createElementVNode("button", {
                                        onClick: _withModifiers($event => (openEditNetworkModal(net)), ["stop"]),
                                        class: "text-blue-500 hover:text-blue-700 p-1",
                                        title: "编辑"
                                      }, _cache[29] || (_cache[29] = [
                                        _createElementVNode("i", { class: "fa-solid fa-pen-to-square" }, null, -1 /* CACHED */)
                                      ]), 8 /* PROPS */, _hoisted_73),
                                      _createElementVNode("button", {
                                        onClick: _withModifiers($event => (confirmDeleteNetwork(net)), ["stop"]),
                                        class: "text-red-500 hover:text-red-700 p-1",
                                        title: "删除"
                                      }, _cache[30] || (_cache[30] = [
                                        _createElementVNode("i", { class: "fa-solid fa-trash" }, null, -1 /* CACHED */)
                                      ]), 8 /* PROPS */, _hoisted_74)
                                    ])
                                  ])
                                ]),
                                _createElementVNode("div", {
                                  class: "mt-4 flex items-center text-xs text-gray-400 cursor-pointer",
                                  onClick: $event => (selectNetwork(net.network_code))
                                }, _cache[31] || (_cache[31] = [
                                  _createElementVNode("span", { class: "mr-2" }, "点击查看设备", -1 /* CACHED */),
                                  _createElementVNode("i", { class: "fa-solid fa-arrow-right group-hover:translate-x-1 transition-transform" }, null, -1 /* CACHED */)
                                ]), 8 /* PROPS */, _hoisted_75)
                              ]))
                            }), 128 /* KEYED_FRAGMENT */))
                          ])),
                      (!loading && filteredNetworks.length === 0)
                        ? (_openBlock(), _createElementBlock("div", _hoisted_76, " 未找到匹配的网络 "))
                        : _createCommentVNode("v-if", true)
                    ]))
                  : (currentView === 'devices')
                    ? (_openBlock(), _createElementBlock("div", _hoisted_77, [
                        _createElementVNode("div", _hoisted_78, [
                          _createElementVNode("div", _hoisted_79, [
                            _createElementVNode("button", {
                              onClick: navigateToNetworks,
                              class: "mr-4 p-2 rounded-full hover:bg-gray-200 transition"
                            }, _cache[32] || (_cache[32] = [
                              _createElementVNode("i", { class: "fa-solid fa-arrow-left text-gray-600" }, null, -1 /* CACHED */)
                            ]), 8 /* PROPS */, _hoisted_80),
                            _createElementVNode("div", null, [
                              _cache[33] || (_cache[33] = _createElementVNode("h2", { class: "text-2xl font-bold text-gray-800" }, "设备详情", -1 /* CACHED */)),
                              _createElementVNode("p", _hoisted_81, "网络: " + _toDisplayString(currentNetworkCode), 1 /* TEXT */)
                            ])
                          ]),
                          _createElementVNode("div", _hoisted_82, [
                            _cache[34] || (_cache[34] = _createElementVNode("span", { class: "absolute inset-y-0 left-0 flex items-center pl-3" }, [
                              _createElementVNode("i", { class: "fa-solid fa-magnifying-glass text-gray-400" })
                            ], -1 /* CACHED */)),
                            _withDirectives(_createElementVNode("input", {
                              "onUpdate:modelValue": $event => ((deviceSearch) = $event),
                              type: "text",
                              placeholder: "搜索 IP 或 设备ID...",
                              class: "w-full pl-10 pr-4 py-2 rounded-lg border focus:outline-none focus:ring-2 focus:ring-blue-500"
                            }, null, 8 /* PROPS */, _hoisted_83), [
                              [_vModelText, deviceSearch]
                            ])
                          ])
                        ]),
                        loading
                          ? (_openBlock(), _createElementBlock("div", _hoisted_84, _cache[35] || (_cache[35] = [
                              _createElementVNode("i", { class: "fa-solid fa-spinner fa-spin text-3xl text-blue-500" }, null, -1 /* CACHED */)
                            ])))
                          : (_openBlock(), _createElementBlock("div", _hoisted_85, [
                              _createElementVNode("table", _hoisted_86, [
                                _cache[45] || (_cache[45] = _createElementVNode("thead", { class: "bg-gray-50" }, [
                                  _createElementVNode("tr", null, [
                                    _createElementVNode("th", { class: "px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider w-16" }),
                                    _createElementVNode("th", { class: "px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "状态"),
                                    _createElementVNode("th", { class: "px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "设备名称 / ID"),
                                    _createElementVNode("th", { class: "px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "IP 地址"),
                                    _createElementVNode("th", { class: "px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "版本"),
                                    _createElementVNode("th", { class: "px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "延迟"),
                                    _createElementVNode("th", { class: "px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "流量 (上/下)"),
                                    _createElementVNode("th", { class: "px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "网速 (上/下)"),
                                    _createElementVNode("th", { class: "px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "最后连接"),
                                    _createElementVNode("th", { class: "px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "操作")
                                  ])
                                ], -1 /* CACHED */)),
                                _createElementVNode("tbody", _hoisted_87, [
                                  (_openBlock(true), _createElementBlock(_Fragment, null, _renderList(mergedDevices, (group) => {
                                    return (_openBlock(), _createElementBlock(_Fragment, { key: group.ip || group.devices[0].device_id }, [
                                      _createCommentVNode(" 主行 "),
                                      _createElementVNode("tr", {
                                        class: _normalizeClass(["hover:bg-gray-50", { 'bg-gray-50': group.expanded }])
                                      }, [
                                        _createElementVNode("td", _hoisted_88, [
                                          _createElementVNode("div", _hoisted_89, [
                                            (group.devices.length > 1)
                                              ? (_openBlock(), _createElementBlock("button", {
                                                  key: 0,
                                                  onClick: $event => (toggleExpand(group)),
                                                  class: "text-gray-500 hover:text-gray-700",
                                                  title: "展开来源"
                                                }, [
                                                  _createElementVNode("i", {
                                                    class: _normalizeClass(["fa-solid", group.expanded ? 'fa-chevron-down' : 'fa-chevron-right'])
                                                  }, null, 2 /* CLASS */)
                                                ], 8 /* PROPS */, _hoisted_90))
                                              : _createCommentVNode("v-if", true),
                                            _createElementVNode("button", {
                                              onClick: $event => (toggleChart(group.ip || group.devices[0].device_id)),
                                              class: "text-gray-400 hover:text-blue-600 transition",
                                              title: "网速历史"
                                            }, _cache[36] || (_cache[36] = [
                                              _createElementVNode("i", { class: "fa-solid fa-chart-line text-xs" }, null, -1 /* CACHED */)
                                            ]), 8 /* PROPS */, _hoisted_91)
                                          ])
                                        ]),
                                        _createElementVNode("td", _hoisted_92, [
                                          (group.hasOnline)
                                            ? (_openBlock(), _createElementBlock("span", _hoisted_93, "在线"))
                                            : (group.hasRemote)
                                              ? (_openBlock(), _createElementBlock("span", _hoisted_94, "远程"))
                                              : (_openBlock(), _createElementBlock("span", _hoisted_95, "离线"))
                                        ]),
                                        _createElementVNode("td", _hoisted_96, [
                                          _createElementVNode("div", _hoisted_97, _toDisplayString(group.devices[0].device_name), 1 /* TEXT */),
                                          _createElementVNode("div", _hoisted_98, _toDisplayString(group.devices[0].device_id), 1 /* TEXT */),
                                          (group.devices.length > 1)
                                            ? (_openBlock(), _createElementBlock("div", _hoisted_99, _toDisplayString(group.devices.length) + " 个来源 ", 1 /* TEXT */))
                                            : _createCommentVNode("v-if", true)
                                        ]),
                                        _createElementVNode("td", _hoisted_100, _toDisplayString(group.ip || '-'), 1 /* TEXT */),
                                        _createElementVNode("td", _hoisted_101, _toDisplayString(group.devices[0].device_version), 1 /* TEXT */),
                                        _createElementVNode("td", _hoisted_102, [
                                          (group.bestLatency !== null)
                                            ? (_openBlock(), _createElementBlock("span", {
                                                key: 0,
                                                class: _normalizeClass([group.bestLatency < 50 ? 'text-green-600' : group.bestLatency < 100 ? 'text-yellow-600' : 'text-red-600', "font-medium"])
                                              }, _toDisplayString(group.bestLatency) + " ms ", 3 /* TEXT, CLASS */))
                                            : (_openBlock(), _createElementBlock("span", _hoisted_103, "-"))
                                        ]),
                                        _createElementVNode("td", _hoisted_104, [
                                          _createElementVNode("div", _hoisted_105, "↑ " + _toDisplayString(formatBytes(group.totalTxBytes)), 1 /* TEXT */),
                                          _createElementVNode("div", _hoisted_106, "↓ " + _toDisplayString(formatBytes(group.totalRxBytes)), 1 /* TEXT */)
                                        ]),
                                        _createElementVNode("td", _hoisted_107, [
                                          _createElementVNode("div", _hoisted_108, "↑ " + _toDisplayString(formatSpeed(group.totalTxSpeed)), 1 /* TEXT */),
                                          _createElementVNode("div", _hoisted_109, "↓ " + _toDisplayString(formatSpeed(group.totalRxSpeed)), 1 /* TEXT */)
                                        ]),
                                        _createElementVNode("td", _hoisted_110, [
                                          _createTextVNode(_toDisplayString(group.devices[0].last_connect_time) + " ", 1 /* TEXT */),
                                          (group.devices[0].disconnect_time)
                                            ? (_openBlock(), _createElementBlock("div", _hoisted_111, " 离线于: " + _toDisplayString(group.devices[0].disconnect_time), 1 /* TEXT */))
                                            : _createCommentVNode("v-if", true)
                                        ]),
                                        _createElementVNode("td", _hoisted_112, [
                                          (group.canDelete)
                                            ? (_openBlock(), _createElementBlock("button", {
                                                key: 0,
                                                onClick: $event => (confirmDeleteDevice(group.devices[0])),
                                                class: "text-red-500 hover:text-red-700",
                                                title: "删除设备"
                                              }, _cache[37] || (_cache[37] = [
                                                _createElementVNode("i", { class: "fa-solid fa-trash" }, null, -1 /* CACHED */)
                                              ]), 8 /* PROPS */, _hoisted_113))
                                            : (_openBlock(), _createElementBlock("span", {
                                                key: 1,
                                                class: "text-gray-300",
                                                title: group.hasOnline ? '在线设备无法删除' : '远程设备无法删除'
                                              }, _cache[38] || (_cache[38] = [
                                                _createElementVNode("i", { class: "fa-solid fa-trash" }, null, -1 /* CACHED */)
                                              ]), 8 /* PROPS */, _hoisted_114))
                                        ])
                                      ], 2 /* CLASS */),
                                      _createCommentVNode(" 网速历史图表行 "),
                                      (expandedCharts[group.ip || group.devices[0].device_id])
                                        ? (_openBlock(), _createElementBlock("tr", _hoisted_115, [
                                            _createElementVNode("td", _hoisted_116, [
                                              _createElementVNode("div", _hoisted_117, [
                                                _createElementVNode("div", _hoisted_118, [
                                                  _cache[39] || (_cache[39] = _createElementVNode("span", { class: "flex items-center" }, [
                                                    _createElementVNode("span", { class: "inline-block w-3 h-0.5 bg-green-400 mr-1" }),
                                                    _createTextVNode("上传速度")
                                                  ], -1 /* CACHED */)),
                                                  _cache[40] || (_cache[40] = _createElementVNode("span", { class: "flex items-center" }, [
                                                    _createElementVNode("span", { class: "inline-block w-3 h-0.5 bg-blue-400 mr-1" }),
                                                    _createTextVNode("下载速度")
                                                  ], -1 /* CACHED */)),
                                                  _createElementVNode("span", {
                                                    class: "ml-auto",
                                                    id: 'chart-max-' + (group.ip || group.devices[0].device_id).replaceAll('.', '-')
                                                  }, null, 8 /* PROPS */, _hoisted_119)
                                                ]),
                                                _createElementVNode("canvas", {
                                                  id: 'chart-' + (group.ip || group.devices[0].device_id).replaceAll('.', '-'),
                                                  class: "traffic-chart rounded"
                                                }, null, 8 /* PROPS */, _hoisted_120)
                                              ])
                                            ])
                                          ]))
                                        : _createCommentVNode("v-if", true),
                                      _createCommentVNode(" 展开的详细行 "),
                                      (group.expanded && group.devices.length > 1)
                                        ? (_openBlock(true), _createElementBlock(_Fragment, { key: 1 }, _renderList(group.devices, (dev, idx) => {
                                            return (_openBlock(), _createElementBlock("tr", {
                                              key: dev.device_id,
                                              class: "bg-gray-50 border-l-4 border-blue-300"
                                            }, [
                                              _cache[41] || (_cache[41] = _createElementVNode("td", { class: "px-4 py-3" }, null, -1 /* CACHED */)),
                                              _createElementVNode("td", _hoisted_121, [
                                                (dev.status === 'Online')
                                                  ? (_openBlock(), _createElementBlock("span", _hoisted_122, "在线"))
                                                  : (dev.status === 'Remote')
                                                    ? (_openBlock(), _createElementBlock("span", _hoisted_123, "远程"))
                                                    : (_openBlock(), _createElementBlock("span", _hoisted_124, "离线"))
                                              ]),
                                              _createElementVNode("td", _hoisted_125, [
                                                _createElementVNode("div", _hoisted_126, [
                                                  (dev.server_addr)
                                                    ? (_openBlock(), _createElementBlock("span", _hoisted_127, _toDisplayString(dev.server_addr), 1 /* TEXT */))
                                                    : (_openBlock(), _createElementBlock("span", _hoisted_128, "本地"))
                                                ])
                                              ]),
                                              _cache[42] || (_cache[42] = _createElementVNode("td", { class: "px-6 py-3 whitespace-nowrap text-xs text-gray-500" }, "-", -1 /* CACHED */)),
                                              _createElementVNode("td", _hoisted_129, _toDisplayString(dev.device_version), 1 /* TEXT */),
                                              _createElementVNode("td", _hoisted_130, [
                                                (dev.latency_ms !== null && dev.latency_ms !== undefined)
                                                  ? (_openBlock(), _createElementBlock("span", {
                                                      key: 0,
                                                      class: _normalizeClass([dev.latency_ms < 50 ? 'text-green-600' : dev.latency_ms < 100 ? 'text-yellow-600' : 'text-red-600', "font-medium"])
                                                    }, _toDisplayString(dev.latency_ms) + " ms ", 3 /* TEXT, CLASS */))
                                                  : (_openBlock(), _createElementBlock("span", _hoisted_131, "-"))
                                              ]),
                                              _createElementVNode("td", _hoisted_132, [
                                                _createElementVNode("div", _hoisted_133, "↑ " + _toDisplayString(formatBytes(dev.tx_bytes)), 1 /* TEXT */),
                                                _createElementVNode("div", _hoisted_134, "↓ " + _toDisplayString(formatBytes(dev.rx_bytes)), 1 /* TEXT */)
                                              ]),
                                              _createElementVNode("td", _hoisted_135, [
                                                _createElementVNode("div", _hoisted_136, "↑ " + _toDisplayString(formatSpeed(dev.tx_speed || 0)), 1 /* TEXT */),
                                                _createElementVNode("div", _hoisted_137, "↓ " + _toDisplayString(formatSpeed(dev.rx_speed || 0)), 1 /* TEXT */)
                                              ]),
                                              _createElementVNode("td", _hoisted_138, _toDisplayString(dev.last_connect_time), 1 /* TEXT */),
                                              _cache[43] || (_cache[43] = _createElementVNode("td", { class: "px-6 py-3" }, null, -1 /* CACHED */))
                                            ]))
                                          }), 128 /* KEYED_FRAGMENT */))
                                        : _createCommentVNode("v-if", true)
                                    ], 64 /* STABLE_FRAGMENT */))
                                  }), 128 /* KEYED_FRAGMENT */)),
                                  (mergedDevices.length === 0)
                                    ? (_openBlock(), _createElementBlock("tr", _hoisted_139, _cache[44] || (_cache[44] = [
                                        _createElementVNode("td", {
                                          colspan: "10",
                                          class: "px-6 py-10 text-center text-gray-500"
                                        }, "无数据", -1 /* CACHED */)
                                      ])))
                                    : _createCommentVNode("v-if", true)
                                ])
                              ])
                            ]))
                      ]))
                    : (currentView === 'servers')
                      ? (_openBlock(), _createElementBlock("div", _hoisted_140, [
                          _createElementVNode("div", _hoisted_141, [
                            _cache[47] || (_cache[47] = _createElementVNode("h2", { class: "text-2xl font-bold text-gray-800" }, "服务器列表", -1 /* CACHED */)),
                            _createElementVNode("button", {
                              onClick: openAddServerModal,
                              class: "bg-green-500 hover:bg-green-600 text-white px-4 py-2 rounded-lg font-medium transition flex items-center"
                            }, _cache[46] || (_cache[46] = [
                              _createElementVNode("i", { class: "fa-solid fa-plus mr-2" }, null, -1 /* CACHED */),
                              _createTextVNode("添加服务器 ")
                            ]), 8 /* PROPS */, _hoisted_142)
                          ]),
                          loading
                            ? (_openBlock(), _createElementBlock("div", _hoisted_143, _cache[48] || (_cache[48] = [
                                _createElementVNode("i", { class: "fa-solid fa-spinner fa-spin text-3xl text-blue-500" }, null, -1 /* CACHED */)
                              ])))
                            : (_openBlock(), _createElementBlock("div", _hoisted_144, [
                                _createCommentVNode(" 主动连接的服务器 "),
                                _createElementVNode("div", _hoisted_145, [
                                  _createElementVNode("h3", _hoisted_146, [
                                    _cache[49] || (_cache[49] = _createElementVNode("i", { class: "fa-solid fa-arrow-right-from-bracket text-blue-600 mr-2" }, null, -1 /* CACHED */)),
                                    _cache[50] || (_cache[50] = _createTextVNode(" 主动连接的服务器 ")),
                                    _createElementVNode("span", _hoisted_147, "(" + _toDisplayString(peerServers.outbound.length) + ")", 1 /* TEXT */)
                                  ]),
                                  (peerServers.outbound.length === 0)
                                    ? (_openBlock(), _createElementBlock("div", _hoisted_148, " 暂无主动连接的服务器 "))
                                    : (_openBlock(), _createElementBlock("div", _hoisted_149, [
                                        (_openBlock(true), _createElementBlock(_Fragment, null, _renderList(peerServers.outbound, (server) => {
                                          return (_openBlock(), _createElementBlock("div", {
                                            key: server.addr,
                                            class: _normalizeClass(["border rounded-lg p-4 hover:shadow-md transition", server.connected ? 'border-green-300 bg-green-50' : 'border-gray-300 bg-gray-50'])
                                          }, [
                                            _createElementVNode("div", _hoisted_150, [
                                              _createElementVNode("div", _hoisted_151, [
                                                _createElementVNode("div", _hoisted_152, [
                                                  _cache[51] || (_cache[51] = _createElementVNode("i", { class: "fa-solid fa-server text-blue-600 mr-2" }, null, -1 /* CACHED */)),
                                                  _createTextVNode(" " + _toDisplayString(server.addr), 1 /* TEXT */)
                                                ])
                                              ]),
                                              _createElementVNode("div", _hoisted_153, [
                                                (server.connected)
                                                  ? (_openBlock(), _createElementBlock("span", _hoisted_154, _cache[52] || (_cache[52] = [
                                                      _createElementVNode("i", { class: "fa-solid fa-circle text-green-600 text-xs mr-1" }, null, -1 /* CACHED */),
                                                      _createTextVNode("在线 ")
                                                    ])))
                                                  : (_openBlock(), _createElementBlock("span", _hoisted_155, _cache[53] || (_cache[53] = [
                                                      _createElementVNode("i", { class: "fa-solid fa-circle text-gray-400 text-xs mr-1" }, null, -1 /* CACHED */),
                                                      _createTextVNode("离线 ")
                                                    ]))),
                                                _createElementVNode("button", {
                                                  onClick: $event => (confirmDeleteServer(server)),
                                                  class: "text-red-500 hover:text-red-700 p-1",
                                                  title: "删除"
                                                }, _cache[54] || (_cache[54] = [
                                                  _createElementVNode("i", { class: "fa-solid fa-trash" }, null, -1 /* CACHED */)
                                                ]), 8 /* PROPS */, _hoisted_156)
                                              ])
                                            ]),
                                            _createElementVNode("div", _hoisted_157, [
                                              _cache[55] || (_cache[55] = _createElementVNode("i", { class: "fa-solid fa-gauge mr-1" }, null, -1 /* CACHED */)),
                                              _cache[56] || (_cache[56] = _createTextVNode(" 延迟: ")),
                                              _createElementVNode("span", _hoisted_158, _toDisplayString(server.latency_ms) + "ms", 1 /* TEXT */)
                                            ])
                                          ], 2 /* CLASS */))
                                        }), 128 /* KEYED_FRAGMENT */))
                                      ]))
                                ]),
                                _createCommentVNode(" 被动接受的服务器 "),
                                _createElementVNode("div", _hoisted_159, [
                                  _createElementVNode("h3", _hoisted_160, [
                                    _cache[57] || (_cache[57] = _createElementVNode("i", { class: "fa-solid fa-arrow-right-to-bracket text-purple-600 mr-2" }, null, -1 /* CACHED */)),
                                    _cache[58] || (_cache[58] = _createTextVNode(" 被动接受的服务器 ")),
                                    _createElementVNode("span", _hoisted_161, "(" + _toDisplayString(peerServers.inbound.length) + ")", 1 /* TEXT */)
                                  ]),
                                  (peerServers.inbound.length === 0)
                                    ? (_openBlock(), _createElementBlock("div", _hoisted_162, " 暂无被动接受的服务器连接 "))
                                    : (_openBlock(), _createElementBlock("div", _hoisted_163, [
                                        (_openBlock(true), _createElementBlock(_Fragment, null, _renderList(peerServers.inbound, (server) => {
                                          return (_openBlock(), _createElementBlock("div", {
                                            key: server.addr,
                                            class: _normalizeClass(["border rounded-lg p-4 hover:shadow-md transition", server.connected ? 'border-green-300 bg-green-50' : 'border-gray-300 bg-gray-50'])
                                          }, [
                                            _createElementVNode("div", _hoisted_164, [
                                              _createElementVNode("div", _hoisted_165, [
                                                _createElementVNode("div", _hoisted_166, [
                                                  _cache[59] || (_cache[59] = _createElementVNode("i", { class: "fa-solid fa-server text-purple-600 mr-2" }, null, -1 /* CACHED */)),
                                                  _createTextVNode(" " + _toDisplayString(server.addr), 1 /* TEXT */)
                                                ])
                                              ]),
                                              (server.connected)
                                                ? (_openBlock(), _createElementBlock("span", _hoisted_167, _cache[60] || (_cache[60] = [
                                                    _createElementVNode("i", { class: "fa-solid fa-circle text-green-600 text-xs mr-1" }, null, -1 /* CACHED */),
                                                    _createTextVNode("在线 ")
                                                  ])))
                                                : (_openBlock(), _createElementBlock("span", _hoisted_168, _cache[61] || (_cache[61] = [
                                                    _createElementVNode("i", { class: "fa-solid fa-circle text-gray-400 text-xs mr-1" }, null, -1 /* CACHED */),
                                                    _createTextVNode("离线 ")
                                                  ])))
                                            ]),
                                            _createElementVNode("div", _hoisted_169, [
                                              _cache[62] || (_cache[62] = _createElementVNode("i", { class: "fa-solid fa-gauge mr-1" }, null, -1 /* CACHED */)),
                                              _cache[63] || (_cache[63] = _createTextVNode(" 延迟: ")),
                                              _createElementVNode("span", _hoisted_170, _toDisplayString(server.latency_ms) + "ms", 1 /* TEXT */)
                                            ])
                                          ], 2 /* CLASS */))
                                        }), 128 /* KEYED_FRAGMENT */))
                                      ]))
                                ])
                              ]))
                        ]))
                      : (currentView === 'wireguard')
                        ? (_openBlock(), _createElementBlock("div", _hoisted_171, [
                            _createElementVNode("div", _hoisted_172, [
                              _cache[67] || (_cache[67] = _createElementVNode("div", null, [
                                _createElementVNode("h2", { class: "text-2xl font-bold text-gray-800" }, "WireGuard 管理"),
                                _createElementVNode("p", { class: "text-sm text-gray-500 mt-1" }, "管理网络级 Peer 身份、在线状态、DNS 与局域网路由")
                              ], -1 /* CACHED */)),
                              _createElementVNode("div", _hoisted_173, [
                                _createElementVNode("label", _hoisted_174, [
                                  _cache[65] || (_cache[65] = _createElementVNode("span", { class: "mb-1" }, "筛选网络", -1 /* CACHED */)),
                                  _withDirectives(_createElementVNode("select", {
                                    "onUpdate:modelValue": $event => ((wireguardNetworkCode) = $event),
                                    onChange: fetchWireGuardData,
                                    class: "rounded-lg border bg-white px-3 py-2 focus:outline-none focus:ring-2 focus:ring-blue-500"
                                  }, [
                                    _cache[64] || (_cache[64] = _createElementVNode("option", { value: "" }, "全部网络", -1 /* CACHED */)),
                                    (_openBlock(true), _createElementBlock(_Fragment, null, _renderList(networks, (net) => {
                                      return (_openBlock(), _createElementBlock("option", {
                                        key: net.network_code,
                                        value: net.network_code
                                      }, _toDisplayString(net.network_code) + "（" + _toDisplayString(net.net) + "） ", 9 /* TEXT, PROPS */, _hoisted_176))
                                    }), 128 /* KEYED_FRAGMENT */))
                                  ], 40 /* PROPS, NEED_HYDRATION */, _hoisted_175), [
                                    [_vModelSelect, wireguardNetworkCode]
                                  ])
                                ]),
                                _createElementVNode("button", {
                                  onClick: openWireGuardPeerModal,
                                  disabled: networks.length === 0 || loading,
                                  class: "self-end bg-green-500 hover:bg-green-600 disabled:bg-gray-300 text-white px-4 py-2 rounded-lg font-medium transition whitespace-nowrap"
                                }, _cache[66] || (_cache[66] = [
                                  _createElementVNode("i", { class: "fa-solid fa-plus mr-2" }, null, -1 /* CACHED */),
                                  _createTextVNode("新增 Peer ")
                                ]), 8 /* PROPS */, _hoisted_177)
                              ])
                            ]),
                            errorMsg
                              ? (_openBlock(), _createElementBlock("div", _hoisted_178, _toDisplayString(errorMsg), 1 /* TEXT */))
                              : _createCommentVNode("v-if", true),
                            (networks.length === 0 && !loading)
                              ? (_openBlock(), _createElementBlock("div", _hoisted_179, " 暂无可管理的网络，请先创建网络。 "))
                              : (loading && wireguardPeers.length === 0)
                                ? (_openBlock(), _createElementBlock("div", _hoisted_180, _cache[68] || (_cache[68] = [
                                    _createElementVNode("i", { class: "fa-solid fa-spinner fa-spin text-3xl text-blue-500" }, null, -1 /* CACHED */)
                                  ])))
                                : (_openBlock(), _createElementBlock("div", _hoisted_181, [
                                    _createElementVNode("div", _hoisted_182, [
                                      _cache[69] || (_cache[69] = _createElementVNode("span", { class: "font-semibold text-gray-700" }, "Peer 列表", -1 /* CACHED */)),
                                      _createElementVNode("span", _hoisted_183, _toDisplayString(wireguardPeers.length) + " 个" + _toDisplayString(wireguardNetworkCode ? '' : '（全部网络）'), 1 /* TEXT */)
                                    ]),
                                    _createElementVNode("table", _hoisted_184, [
                                      _cache[74] || (_cache[74] = _createElementVNode("thead", { class: "bg-gray-50" }, [
                                        _createElementVNode("tr", null, [
                                          _createElementVNode("th", { class: "px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "Peer ID"),
                                          _createElementVNode("th", { class: "px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "网络"),
                                          _createElementVNode("th", { class: "px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "公钥"),
                                          _createElementVNode("th", { class: "px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "状态"),
                                          _createElementVNode("th", { class: "px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider min-w-72" }, "保留 IP"),
                                          _createElementVNode("th", { class: "px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider min-w-72" }, "DNS / 路由"),
                                          _createElementVNode("th", { class: "px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" }, "更新时间"),
                                          _createElementVNode("th", { class: "px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider" }, "操作")
                                        ])
                                      ], -1 /* CACHED */)),
                                      _createElementVNode("tbody", _hoisted_185, [
                                        (_openBlock(true), _createElementBlock(_Fragment, null, _renderList(wireguardPeers, (peer, index) => {
                                          return (_openBlock(), _createElementBlock("tr", {
                                            key: wireguardPeerKey(peer),
                                            class: _normalizeClass(wireguardPeerRowClass(peer, index))
                                          }, [
                                            _createElementVNode("td", _hoisted_186, _toDisplayString(peer.peer_id), 1 /* TEXT */),
                                            _createElementVNode("td", _hoisted_187, _toDisplayString(peer.network_code), 1 /* TEXT */),
                                            _createElementVNode("td", _hoisted_188, [
                                              _createElementVNode("code", {
                                                class: "block max-w-64 truncate text-xs text-gray-600",
                                                title: peer.public_key
                                              }, _toDisplayString(peer.public_key), 9 /* TEXT, PROPS */, _hoisted_189)
                                            ]),
                                            _createElementVNode("td", _hoisted_190, [
                                              _createElementVNode("span", {
                                                class: _normalizeClass([wireguardStatusClass(peer.status), "px-2 py-1 text-xs font-semibold rounded-full"])
                                              }, _toDisplayString(wireguardStatusLabel(peer.status)), 3 /* TEXT, CLASS */)
                                            ]),
                                            _createElementVNode("td", _hoisted_191, [
                                              _createElementVNode("div", _hoisted_192, [
                                                _withDirectives(_createElementVNode("input", {
                                                  "onUpdate:modelValue": $event => ((wireguardIpDrafts[wireguardPeerKey(peer)]) = $event),
                                                  type: "text",
                                                  placeholder: "如 10.26.0.2",
                                                  class: "w-36 rounded border px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                                                }, null, 8 /* PROPS */, _hoisted_193), [
                                                  [_vModelText, wireguardIpDrafts[wireguardPeerKey(peer)]]
                                                ]),
                                                _createElementVNode("button", {
                                                  onClick: $event => (reserveWireGuardPeerIp(peer)),
                                                  disabled: loading,
                                                  class: "text-sm text-blue-600 hover:text-blue-800 disabled:text-gray-300"
                                                }, "预留", 8 /* PROPS */, _hoisted_194),
                                                (wireguardIpMap[wireguardPeerKey(peer)])
                                                  ? (_openBlock(), _createElementBlock("button", {
                                                      key: 0,
                                                      onClick: $event => (releaseWireGuardPeerIp(peer)),
                                                      disabled: loading,
                                                      class: "text-sm text-red-600 hover:text-red-800 disabled:text-gray-300"
                                                    }, "释放", 8 /* PROPS */, _hoisted_195))
                                                  : _createCommentVNode("v-if", true)
                                              ])
                                            ]),
                                            _createElementVNode("td", _hoisted_196, [
                                              _createElementVNode("p", null, [
                                                _cache[70] || (_cache[70] = _createElementVNode("span", { class: "text-gray-400" }, "DNS：", -1 /* CACHED */)),
                                                _createTextVNode(_toDisplayString(peer.dns_servers?.join(', ') || '未配置'), 1 /* TEXT */),
                                                (peer.dns_inherited)
                                                  ? (_openBlock(), _createElementBlock("span", _hoisted_197, "（继承）"))
                                                  : _createCommentVNode("v-if", true)
                                              ]),
                                              _createElementVNode("p", _hoisted_198, [
                                                _cache[71] || (_cache[71] = _createElementVNode("span", { class: "text-gray-400" }, "Keepalive：", -1 /* CACHED */)),
                                                _createTextVNode(_toDisplayString(peer.persistent_keepalive) + " 秒", 1 /* TEXT */)
                                              ]),
                                              _createElementVNode("p", _hoisted_199, [
                                                _cache[72] || (_cache[72] = _createElementVNode("span", { class: "text-gray-400" }, "路由：", -1 /* CACHED */)),
                                                _createTextVNode(_toDisplayString(peer.routes?.length || 0) + " 条", 1 /* TEXT */)
                                              ]),
                                              _createElementVNode("p", _hoisted_200, [
                                                _cache[73] || (_cache[73] = _createElementVNode("span", { class: "text-gray-400" }, "客户端配置：", -1 /* CACHED */)),
                                                _createTextVNode(_toDisplayString(peer.config_available ? '可下载' : '仅公钥'), 1 /* TEXT */)
                                              ])
                                            ]),
                                            _createElementVNode("td", _hoisted_201, _toDisplayString(formatTimestamp(peer.updated_at)), 1 /* TEXT */),
                                            _createElementVNode("td", _hoisted_202, [
                                              _createElementVNode("button", {
                                                onClick: $event => (openWireGuardProfileModal(peer)),
                                                disabled: loading,
                                                class: "mr-3 text-indigo-600 hover:text-indigo-800 disabled:text-gray-300"
                                              }, "配置", 8 /* PROPS */, _hoisted_203),
                                              (peer.config_available)
                                                ? (_openBlock(), _createElementBlock("button", {
                                                    key: 0,
                                                    onClick: $event => (openStoredWireGuardConfig(peer)),
                                                    disabled: loading,
                                                    class: "mr-3 text-green-600 hover:text-green-800 disabled:text-gray-300"
                                                  }, "下载", 8 /* PROPS */, _hoisted_204))
                                                : _createCommentVNode("v-if", true),
                                              _createElementVNode("button", {
                                                onClick: $event => (setWireGuardPeerEnabled(peer, !peer.enabled)),
                                                disabled: loading,
                                                class: "mr-3 text-blue-600 hover:text-blue-800 disabled:text-gray-300"
                                              }, _toDisplayString(peer.enabled ? '禁用' : '启用'), 9 /* TEXT, PROPS */, _hoisted_205),
                                              _createElementVNode("button", {
                                                onClick: $event => (confirmDeleteWireGuardPeer(peer)),
                                                disabled: loading,
                                                class: "text-red-600 hover:text-red-800 disabled:text-gray-300"
                                              }, "删除", 8 /* PROPS */, _hoisted_206)
                                            ])
                                          ], 2 /* CLASS */))
                                        }), 128 /* KEYED_FRAGMENT */)),
                                        (wireguardPeers.length === 0)
                                          ? (_openBlock(), _createElementBlock("tr", _hoisted_207, [
                                              _createElementVNode("td", _hoisted_208, _toDisplayString(wireguardNetworkCode ? '当前筛选网络暂无 WireGuard Peer' : '暂无 WireGuard Peer'), 1 /* TEXT */)
                                            ]))
                                          : _createCommentVNode("v-if", true)
                                      ])
                                    ])
                                  ]))
                          ]))
                        : _createCommentVNode("v-if", true)
          ]),
          _: 1 /* STABLE */
        })
      ]),
      _createCommentVNode(" 新增/编辑网络模态框 "),
      showNetworkModal
        ? (_openBlock(), _createElementBlock("div", {
            key: 0,
            class: "modal-mask",
            onClick: _withModifiers(closeNetworkModal, ["self"])
          }, [
            _createElementVNode("div", _hoisted_210, [
              _createElementVNode("h3", _hoisted_211, _toDisplayString(isEditMode ? '编辑网络' : '新增网络'), 1 /* TEXT */),
              _createElementVNode("form", {
                onSubmit: _withModifiers(submitNetworkForm, ["prevent"])
              }, [
                _createElementVNode("div", _hoisted_213, [
                  _cache[75] || (_cache[75] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "网络编号", -1 /* CACHED */)),
                  _withDirectives(_createElementVNode("input", {
                    "onUpdate:modelValue": $event => ((networkForm.network_code) = $event),
                    type: "text",
                    disabled: isEditMode,
                    class: _normalizeClass([{'bg-gray-100': isEditMode}, "shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-blue-500"]),
                    placeholder: "如: office, home",
                    required: ""
                  }, null, 10 /* CLASS, PROPS */, _hoisted_214), [
                    [_vModelText, networkForm.network_code]
                  ])
                ]),
                _createElementVNode("div", _hoisted_215, [
                  _cache[76] || (_cache[76] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "网关地址", -1 /* CACHED */)),
                  _withDirectives(_createElementVNode("input", {
                    "onUpdate:modelValue": $event => ((networkForm.gateway) = $event),
                    type: "text",
                    class: "shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-blue-500",
                    placeholder: "如: 10.26.0.1",
                    required: ""
                  }, null, 8 /* PROPS */, _hoisted_216), [
                    [_vModelText, networkForm.gateway]
                  ])
                ]),
                _createElementVNode("div", _hoisted_217, [
                  _cache[77] || (_cache[77] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "掩码长度", -1 /* CACHED */)),
                  _withDirectives(_createElementVNode("input", {
                    "onUpdate:modelValue": $event => ((networkForm.netmask) = $event),
                    type: "number",
                    min: "8",
                    max: "30",
                    class: "shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-blue-500",
                    placeholder: "如: 24",
                    required: ""
                  }, null, 8 /* PROPS */, _hoisted_218), [
                    [
                      _vModelText,
                      networkForm.netmask,
                      void 0,
                      { number: true }
                    ]
                  ])
                ]),
                _createElementVNode("div", _hoisted_219, [
                  _cache[78] || (_cache[78] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "IP租期（秒）", -1 /* CACHED */)),
                  _withDirectives(_createElementVNode("input", {
                    "onUpdate:modelValue": $event => ((networkForm.lease_duration) = $event),
                    type: "number",
                    min: "60",
                    class: "shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-blue-500",
                    placeholder: "如: 86400 (24小时)"
                  }, null, 8 /* PROPS */, _hoisted_220), [
                    [
                      _vModelText,
                      networkForm.lease_duration,
                      void 0,
                      { number: true }
                    ]
                  ]),
                  _cache[79] || (_cache[79] = _createElementVNode("p", { class: "text-gray-400 text-xs mt-1" }, "新增时不填则使用默认值", -1 /* CACHED */))
                ]),
                _createElementVNode("div", _hoisted_221, [
                  _createElementVNode("button", {
                    type: "button",
                    onClick: closeNetworkModal,
                    class: "px-4 py-2 text-gray-600 hover:text-gray-800"
                  }, "取消", 8 /* PROPS */, _hoisted_222),
                  _createElementVNode("button", {
                    type: "submit",
                    disabled: loading,
                    class: "bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded font-medium transition"
                  }, _toDisplayString(loading ? '提交中...' : '确定'), 9 /* TEXT, PROPS */, _hoisted_223)
                ])
              ], 40 /* PROPS, NEED_HYDRATION */, _hoisted_212),
              modalErrorMsg
                ? (_openBlock(), _createElementBlock("p", _hoisted_224, _toDisplayString(modalErrorMsg), 1 /* TEXT */))
                : _createCommentVNode("v-if", true)
            ])
          ], 8 /* PROPS */, _hoisted_209))
        : _createCommentVNode("v-if", true),
      _createCommentVNode(" 确认删除模态框 "),
      showConfirmModal
        ? (_openBlock(), _createElementBlock("div", {
            key: 1,
            class: "modal-mask",
            onClick: _withModifiers(closeConfirmModal, ["self"])
          }, [
            _createElementVNode("div", _hoisted_226, [
              _cache[80] || (_cache[80] = _createElementVNode("h3", { class: "text-xl font-bold mb-4 text-red-600" }, [
                _createElementVNode("i", { class: "fa-solid fa-triangle-exclamation mr-2" }),
                _createTextVNode("确认删除 ")
              ], -1 /* CACHED */)),
              _createElementVNode("p", _hoisted_227, _toDisplayString(confirmMessage), 1 /* TEXT */),
              _createElementVNode("div", _hoisted_228, [
                _createElementVNode("button", {
                  onClick: closeConfirmModal,
                  class: "px-4 py-2 text-gray-600 hover:text-gray-800"
                }, "取消", 8 /* PROPS */, _hoisted_229),
                _createElementVNode("button", {
                  onClick: executeDelete,
                  disabled: loading,
                  class: "bg-red-600 hover:bg-red-700 text-white px-4 py-2 rounded font-medium transition"
                }, _toDisplayString(loading ? '删除中...' : '确认删除'), 9 /* TEXT, PROPS */, _hoisted_230)
              ]),
              modalErrorMsg
                ? (_openBlock(), _createElementBlock("p", _hoisted_231, _toDisplayString(modalErrorMsg), 1 /* TEXT */))
                : _createCommentVNode("v-if", true)
            ])
          ], 8 /* PROPS */, _hoisted_225))
        : _createCommentVNode("v-if", true),
      _createCommentVNode(" 添加服务器模态框 "),
      showAddServerModal
        ? (_openBlock(), _createElementBlock("div", {
            key: 2,
            class: "modal-mask",
            onClick: _withModifiers(closeAddServerModal, ["self"])
          }, [
            _createElementVNode("div", _hoisted_233, [
              _cache[83] || (_cache[83] = _createElementVNode("h3", { class: "text-xl font-bold mb-4" }, "添加服务器", -1 /* CACHED */)),
              _createElementVNode("form", {
                onSubmit: _withModifiers(submitAddServer, ["prevent"])
              }, [
                _createElementVNode("div", _hoisted_235, [
                  _cache[81] || (_cache[81] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "服务器地址", -1 /* CACHED */)),
                  _withDirectives(_createElementVNode("input", {
                    "onUpdate:modelValue": $event => ((serverForm.server_addr) = $event),
                    type: "text",
                    class: "shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-blue-500",
                    placeholder: "如: 192.168.1.100:8080",
                    required: ""
                  }, null, 8 /* PROPS */, _hoisted_236), [
                    [_vModelText, serverForm.server_addr]
                  ]),
                  _cache[82] || (_cache[82] = _createElementVNode("p", { class: "text-gray-400 text-xs mt-1" }, "格式: IP:端口 或 域名:端口", -1 /* CACHED */))
                ]),
                _createElementVNode("div", _hoisted_237, [
                  _createElementVNode("button", {
                    type: "button",
                    onClick: closeAddServerModal,
                    class: "px-4 py-2 text-gray-600 hover:text-gray-800"
                  }, "取消", 8 /* PROPS */, _hoisted_238),
                  _createElementVNode("button", {
                    type: "submit",
                    disabled: loading,
                    class: "bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded font-medium transition"
                  }, _toDisplayString(loading ? '添加中...' : '确定'), 9 /* TEXT, PROPS */, _hoisted_239)
                ])
              ], 40 /* PROPS, NEED_HYDRATION */, _hoisted_234),
              modalErrorMsg
                ? (_openBlock(), _createElementBlock("p", _hoisted_240, _toDisplayString(modalErrorMsg), 1 /* TEXT */))
                : _createCommentVNode("v-if", true)
            ])
          ], 8 /* PROPS */, _hoisted_232))
        : _createCommentVNode("v-if", true),
      _createCommentVNode(" 新增 WireGuard Peer 模态框 "),
      showWireGuardPeerModal
        ? (_openBlock(), _createElementBlock("div", _hoisted_241, [
            _createElementVNode("div", _hoisted_242, [
              _createElementVNode("h3", _hoisted_243, _toDisplayString(generatedWireGuardPeer ? (wireguardGeneratedPeerNew ? '保存 WireGuard 客户端密钥' : '下载 WireGuard 客户端配置') : (wireguardEditingPeer ? '编辑 WireGuard Peer 配置' : '新增 WireGuard Peer')), 1 /* TEXT */),
              generatedWireGuardPeer
                ? (_openBlock(), _createElementBlock("div", _hoisted_244, [
                    wireguardGeneratedPeerNew
                      ? (_openBlock(), _createElementBlock("div", _hoisted_245, _cache[84] || (_cache[84] = [
                          _createElementVNode("p", { class: "font-bold" }, [
                            _createElementVNode("i", { class: "fa-solid fa-triangle-exclamation mr-2" }),
                            _createTextVNode("客户端配置只显示这一次")
                          ], -1 /* CACHED */),
                          _createElementVNode("p", { class: "text-sm mt-1" }, "请立即下载配置或扫码导入。关闭或完成后，服务器无法恢复其中的私钥。", -1 /* CACHED */)
                        ])))
                      : _createCommentVNode("v-if", true),
                    _createElementVNode("dl", _hoisted_246, [
                      _createElementVNode("div", _hoisted_247, [
                        _cache[85] || (_cache[85] = _createElementVNode("dt", { class: "text-gray-500" }, "网络", -1 /* CACHED */)),
                        _createElementVNode("dd", _hoisted_248, _toDisplayString(generatedWireGuardPeer.peer.network_code), 1 /* TEXT */)
                      ]),
                      _createElementVNode("div", _hoisted_249, [
                        _cache[86] || (_cache[86] = _createElementVNode("dt", { class: "text-gray-500" }, "设备名称", -1 /* CACHED */)),
                        _createElementVNode("dd", _hoisted_250, _toDisplayString(generatedWireGuardPeer.peer.peer_id), 1 /* TEXT */)
                      ]),
                      _createElementVNode("div", _hoisted_251, [
                        _cache[87] || (_cache[87] = _createElementVNode("dt", { class: "text-gray-500" }, "虚拟 IP", -1 /* CACHED */)),
                        _createElementVNode("dd", _hoisted_252, _toDisplayString(generatedWireGuardPeer.peer.ip || '-'), 1 /* TEXT */)
                      ])
                    ]),
                    _createElementVNode("div", _hoisted_253, [
                      _cache[89] || (_cache[89] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "客户端私钥", -1 /* CACHED */)),
                      _createElementVNode("textarea", {
                        value: generatedWireGuardPeer.private_key,
                        readonly: "",
                        rows: "2",
                        spellcheck: "false",
                        class: "border rounded w-full py-2 px-3 bg-gray-50 font-mono text-sm break-all resize-none"
                      }, null, 8 /* PROPS */, _hoisted_254),
                      _createElementVNode("div", _hoisted_255, [
                        _createElementVNode("p", {
                          class: _normalizeClass(["text-xs", wireguardPrivateKeyCopied ? 'text-green-600' : 'text-gray-500'])
                        }, _toDisplayString(wireguardPrivateKeyCopied ? '已复制到剪贴板' : '请保存到安全位置，不要发送给他人。'), 3 /* TEXT, CLASS */),
                        _createElementVNode("button", {
                          type: "button",
                          onClick: copyGeneratedWireGuardPrivateKey,
                          class: "shrink-0 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded text-sm font-medium"
                        }, _cache[88] || (_cache[88] = [
                          _createElementVNode("i", { class: "fa-regular fa-copy mr-1" }, null, -1 /* CACHED */),
                          _createTextVNode("复制私钥 ")
                        ]), 8 /* PROPS */, _hoisted_256)
                      ])
                    ]),
                    _createElementVNode("div", _hoisted_257, [
                      _createElementVNode("div", _hoisted_258, [
                        _createElementVNode("div", _hoisted_259, [
                          _cache[90] || (_cache[90] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold" }, "完整客户端配置", -1 /* CACHED */)),
                          _createElementVNode("span", _hoisted_260, _toDisplayString(generatedWireGuardConfigFilename), 1 /* TEXT */)
                        ]),
                        _createElementVNode("textarea", {
                          value: generatedWireGuardConfig,
                          readonly: "",
                          rows: "10",
                          spellcheck: "false",
                          class: "border rounded w-full py-2 px-3 bg-gray-50 font-mono text-xs resize-none"
                        }, null, 8 /* PROPS */, _hoisted_261),
                        _createElementVNode("div", _hoisted_262, [
                          _createElementVNode("button", {
                            type: "button",
                            onClick: copyGeneratedWireGuardConfig,
                            class: "bg-gray-700 hover:bg-gray-800 text-white px-4 py-2 rounded text-sm font-medium"
                          }, [
                            _cache[91] || (_cache[91] = _createElementVNode("i", { class: "fa-regular fa-copy mr-1" }, null, -1 /* CACHED */)),
                            _createTextVNode(_toDisplayString(wireguardConfigCopied ? '配置已复制' : '复制配置'), 1 /* TEXT */)
                          ], 8 /* PROPS */, _hoisted_263),
                          _createElementVNode("button", {
                            type: "button",
                            onClick: downloadGeneratedWireGuardConfig,
                            class: "bg-green-600 hover:bg-green-700 text-white px-4 py-2 rounded text-sm font-medium"
                          }, [
                            _cache[92] || (_cache[92] = _createElementVNode("i", { class: "fa-solid fa-download mr-1" }, null, -1 /* CACHED */)),
                            _createTextVNode(_toDisplayString(wireguardConfigDownloaded ? '已下载 .conf' : '下载 .conf'), 1 /* TEXT */)
                          ], 8 /* PROPS */, _hoisted_264)
                        ])
                      ]),
                      _createElementVNode("div", _hoisted_265, [
                        _cache[93] || (_cache[93] = _createElementVNode("p", { class: "text-sm font-bold text-gray-700 mb-2" }, "WireGuard 扫码导入", -1 /* CACHED */)),
                        _createElementVNode("canvas", _hoisted_266, null, 512 /* NEED_PATCH */),
                        _cache[94] || (_cache[94] = _createElementVNode("p", { class: "text-xs text-gray-500 text-center mt-2" }, "二维码包含客户端私钥，请勿截图分享。", -1 /* CACHED */))
                      ])
                    ]),
                    _createElementVNode("details", _hoisted_267, [
                      _cache[98] || (_cache[98] = _createElementVNode("summary", { class: "cursor-pointer font-medium text-gray-700" }, "查看公钥信息", -1 /* CACHED */)),
                      _createElementVNode("div", _hoisted_268, [
                        _createElementVNode("div", null, [
                          _cache[95] || (_cache[95] = _createElementVNode("p", { class: "text-gray-500 mb-1" }, "客户端公钥", -1 /* CACHED */)),
                          _createElementVNode("code", _hoisted_269, _toDisplayString(generatedWireGuardPeer.peer.public_key), 1 /* TEXT */)
                        ]),
                        _createElementVNode("div", null, [
                          _cache[96] || (_cache[96] = _createElementVNode("p", { class: "text-gray-500 mb-1" }, "服务端公钥", -1 /* CACHED */)),
                          _createElementVNode("code", _hoisted_270, _toDisplayString(generatedWireGuardPeer.server_public_key), 1 /* TEXT */)
                        ]),
                        _createElementVNode("div", null, [
                          _cache[97] || (_cache[97] = _createElementVNode("p", { class: "text-gray-500 mb-1" }, "公网 Endpoint", -1 /* CACHED */)),
                          _createElementVNode("code", _hoisted_271, _toDisplayString(generatedWireGuardPeer.endpoint), 1 /* TEXT */)
                        ])
                      ])
                    ]),
                    wireguardGeneratedPeerNew
                      ? (_openBlock(), _createElementBlock("label", _hoisted_272, [
                          _withDirectives(_createElementVNode("input", {
                            "onUpdate:modelValue": $event => ((wireguardPrivateKeySaved) = $event),
                            type: "checkbox",
                            class: "mr-2 mt-0.5 h-4 w-4"
                          }, null, 8 /* PROPS */, _hoisted_273), [
                            [_vModelCheckbox, wireguardPrivateKeySaved]
                          ]),
                          _cache[99] || (_cache[99] = _createElementVNode("span", null, "我确认已经下载配置、扫码导入或安全保存客户端私钥", -1 /* CACHED */))
                        ]))
                      : _createCommentVNode("v-if", true),
                    _createElementVNode("div", _hoisted_274, [
                      wireguardGeneratedPeerNew
                        ? (_openBlock(), _createElementBlock("button", {
                            key: 0,
                            type: "button",
                            onClick: discardGeneratedWireGuardPeer,
                            disabled: loading,
                            class: "px-4 py-2 text-red-600 hover:text-red-800 disabled:text-gray-400"
                          }, " 放弃并删除 Peer ", 8 /* PROPS */, _hoisted_275))
                        : _createCommentVNode("v-if", true),
                      _createElementVNode("button", {
                        type: "button",
                        onClick: finishGeneratedWireGuardPeer,
                        disabled: loading || (wireguardGeneratedPeerNew && !wireguardPrivateKeySaved),
                        class: "bg-blue-600 hover:bg-blue-700 disabled:bg-gray-300 text-white px-4 py-2 rounded font-medium"
                      }, _toDisplayString(wireguardGeneratedPeerNew ? '已保存，完成' : '关闭'), 9 /* TEXT, PROPS */, _hoisted_276)
                    ])
                  ]))
                : (_openBlock(), _createElementBlock("form", {
                    key: 1,
                    onSubmit: _withModifiers(submitWireGuardPeer, ["prevent"])
                  }, [
                    _createElementVNode("div", _hoisted_278, [
                      _cache[101] || (_cache[101] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "网络", -1 /* CACHED */)),
                      (!wireguardEditingPeer)
                        ? _withDirectives((_openBlock(), _createElementBlock("select", {
                            key: 0,
                            "onUpdate:modelValue": $event => ((wireguardPeerForm.network_code) = $event),
                            required: "",
                            class: "border rounded w-full py-2 px-3 bg-white focus:outline-none focus:ring-2 focus:ring-blue-500"
                          }, [
                            _cache[100] || (_cache[100] = _createElementVNode("option", {
                              value: "",
                              disabled: ""
                            }, "请选择网络", -1 /* CACHED */)),
                            (_openBlock(true), _createElementBlock(_Fragment, null, _renderList(networks, (net) => {
                              return (_openBlock(), _createElementBlock("option", {
                                key: net.network_code,
                                value: net.network_code
                              }, _toDisplayString(net.network_code) + "（" + _toDisplayString(net.net) + "） ", 9 /* TEXT, PROPS */, _hoisted_280))
                            }), 128 /* KEYED_FRAGMENT */))
                          ], 8 /* PROPS */, _hoisted_279)), [
                            [_vModelSelect, wireguardPeerForm.network_code]
                          ])
                        : (_openBlock(), _createElementBlock("input", {
                            key: 1,
                            value: wireguardEditingPeer.network_code,
                            type: "text",
                            disabled: "",
                            class: "border rounded w-full py-2 px-3 bg-gray-100 text-gray-600"
                          }, null, 8 /* PROPS */, _hoisted_281))
                    ]),
                    _createElementVNode("div", _hoisted_282, [
                      _cache[102] || (_cache[102] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "设备名称（Peer ID）", -1 /* CACHED */)),
                      _withDirectives(_createElementVNode("input", {
                        "onUpdate:modelValue": $event => ((wireguardPeerForm.peer_id) = $event),
                        type: "text",
                        autocomplete: "off",
                        disabled: !!wireguardEditingPeer,
                        class: "border rounded w-full py-2 px-3 focus:outline-none focus:ring-2 focus:ring-blue-500",
                        placeholder: "如：张三的笔记本",
                        required: ""
                      }, null, 8 /* PROPS */, _hoisted_283), [
                        [_vModelText, wireguardPeerForm.peer_id]
                      ]),
                      _cache[103] || (_cache[103] = _createElementVNode("p", { class: "text-gray-400 text-xs mt-1" }, "日常通过设备名称识别，无需记忆公钥。", -1 /* CACHED */))
                    ]),
                    (!wireguardEditingPeer)
                      ? (_openBlock(), _createElementBlock("div", _hoisted_284, [
                          _cache[108] || (_cache[108] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "添加方式", -1 /* CACHED */)),
                          _createElementVNode("div", _hoisted_285, [
                            _createElementVNode("label", {
                              class: _normalizeClass(["cursor-pointer rounded border-2 p-3", wireguardPeerMode === 'generated' ? 'border-blue-500 bg-blue-50' : 'border-gray-200'])
                            }, [
                              _withDirectives(_createElementVNode("input", {
                                "onUpdate:modelValue": $event => ((wireguardPeerMode) = $event),
                                type: "radio",
                                value: "generated",
                                class: "mr-2"
                              }, null, 8 /* PROPS */, _hoisted_286), [
                                [_vModelRadio, wireguardPeerMode]
                              ]),
                              _cache[104] || (_cache[104] = _createElementVNode("span", { class: "font-medium" }, "一键生成", -1 /* CACHED */)),
                              _cache[105] || (_cache[105] = _createElementVNode("span", { class: "block text-xs text-gray-500 mt-1 ml-6" }, "自动生成密钥并分配虚拟 IP", -1 /* CACHED */))
                            ], 2 /* CLASS */),
                            _createElementVNode("label", {
                              class: _normalizeClass(["cursor-pointer rounded border-2 p-3", wireguardPeerMode === 'existing' ? 'border-blue-500 bg-blue-50' : 'border-gray-200'])
                            }, [
                              _withDirectives(_createElementVNode("input", {
                                "onUpdate:modelValue": $event => ((wireguardPeerMode) = $event),
                                type: "radio",
                                value: "existing",
                                class: "mr-2"
                              }, null, 8 /* PROPS */, _hoisted_287), [
                                [_vModelRadio, wireguardPeerMode]
                              ]),
                              _cache[106] || (_cache[106] = _createElementVNode("span", { class: "font-medium" }, "粘贴已有公钥", -1 /* CACHED */)),
                              _cache[107] || (_cache[107] = _createElementVNode("span", { class: "block text-xs text-gray-500 mt-1 ml-6" }, "适合已经生成密钥的设备", -1 /* CACHED */))
                            ], 2 /* CLASS */)
                          ])
                        ]))
                      : _createCommentVNode("v-if", true),
                    (!wireguardEditingPeer && wireguardPeerMode === 'existing')
                      ? (_openBlock(), _createElementBlock("div", _hoisted_288, [
                          _cache[109] || (_cache[109] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "WireGuard 公钥", -1 /* CACHED */)),
                          _withDirectives(_createElementVNode("input", {
                            "onUpdate:modelValue": $event => ((wireguardPeerForm.public_key) = $event),
                            type: "text",
                            autocomplete: "off",
                            spellcheck: "false",
                            class: "border rounded w-full py-2 px-3 font-mono text-sm focus:outline-none focus:ring-2 focus:ring-blue-500",
                            placeholder: "44 字符、带填充的 Base64 公钥",
                            required: ""
                          }, null, 8 /* PROPS */, _hoisted_289), [
                            [_vModelText, wireguardPeerForm.public_key]
                          ]),
                          _cache[110] || (_cache[110] = _createElementVNode("p", { class: "text-gray-400 text-xs mt-1" }, "必须是 32 字节公钥的规范 Base64 编码。", -1 /* CACHED */))
                        ]))
                      : _createCommentVNode("v-if", true),
                    _createElementVNode("div", _hoisted_290, [
                      _createElementVNode("label", _hoisted_291, [
                        _withDirectives(_createElementVNode("input", {
                          "onUpdate:modelValue": $event => ((wireguardPeerForm.dns_inherited) = $event),
                          type: "checkbox",
                          class: "mr-2 h-4 w-4"
                        }, null, 8 /* PROPS */, _hoisted_292), [
                          [_vModelCheckbox, wireguardPeerForm.dns_inherited]
                        ]),
                        _cache[111] || (_cache[111] = _createTextVNode(" 继承服务端全局 DNS "))
                      ]),
                      (!wireguardPeerForm.dns_inherited)
                        ? _withDirectives((_openBlock(), _createElementBlock("input", {
                            key: 0,
                            "onUpdate:modelValue": $event => ((wireguardPeerForm.dns_servers) = $event),
                            type: "text",
                            autocomplete: "off",
                            class: "mt-3 border rounded w-full py-2 px-3 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500",
                            placeholder: "如：1.1.1.1, 8.8.8.8"
                          }, null, 8 /* PROPS */, _hoisted_293)), [
                            [_vModelText, wireguardPeerForm.dns_servers]
                          ])
                        : _createCommentVNode("v-if", true),
                      _cache[112] || (_cache[112] = _createElementVNode("p", { class: "text-gray-400 text-xs mt-1" }, "最多 4 个 IPv4/IPv6 地址，逗号或空格分隔。", -1 /* CACHED */))
                    ]),
                    _createElementVNode("div", _hoisted_294, [
                      _cache[113] || (_cache[113] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "PersistentKeepalive（秒）", -1 /* CACHED */)),
                      _withDirectives(_createElementVNode("input", {
                        "onUpdate:modelValue": $event => ((wireguardPeerForm.persistent_keepalive) = $event),
                        type: "number",
                        min: "0",
                        max: "65535",
                        class: "border rounded w-full py-2 px-3 focus:outline-none focus:ring-2 focus:ring-blue-500"
                      }, null, 8 /* PROPS */, _hoisted_295), [
                        [
                          _vModelText,
                          wireguardPeerForm.persistent_keepalive,
                          void 0,
                          { number: true }
                        ]
                      ])
                    ]),
                    _createElementVNode("div", _hoisted_296, [
                      _cache[119] || (_cache[119] = _createElementVNode("label", { class: "block text-gray-700 text-sm font-bold mb-2" }, "Peer 后方局域网路由", -1 /* CACHED */)),
                      _createElementVNode("div", _hoisted_297, [
                        (_openBlock(true), _createElementBlock(_Fragment, null, _renderList(wireguardPeerForm.routes, (route, index) => {
                          return (_openBlock(), _createElementBlock("div", {
                            key: index,
                            class: "flex flex-col sm:flex-row sm:items-end gap-3 rounded border border-gray-200 p-3"
                          }, [
                            _createElementVNode("div", _hoisted_298, [
                              _cache[116] || (_cache[116] = _createElementVNode("label", { class: "block text-gray-600 text-xs font-medium mb-1" }, "局域网 CIDR", -1 /* CACHED */)),
                              _createElementVNode("div", _hoisted_299, [
                                _withDirectives(_createElementVNode("input", {
                                  "onUpdate:modelValue": $event => ((route.lan_network) = $event),
                                  type: "text",
                                  inputmode: "decimal",
                                  autocomplete: "off",
                                  class: "border rounded-l w-full py-2 px-3 font-mono text-sm focus:outline-none focus:ring-2 focus:ring-blue-500",
                                  placeholder: "如：192.168.10.0"
                                }, null, 8 /* PROPS */, _hoisted_300), [
                                  [_vModelText, route.lan_network]
                                ]),
                                _withDirectives(_createElementVNode("select", {
                                  "onUpdate:modelValue": $event => ((route.lan_prefix) = $event),
                                  "aria-label": "局域网 CIDR 前缀",
                                  class: "border border-l-0 rounded-r bg-gray-100 text-gray-500 px-2 py-2 font-mono text-sm whitespace-nowrap focus:outline-none focus:ring-2 focus:ring-blue-500"
                                }, [
                                  (!['24', '32'].includes(String(route.lan_prefix)))
                                    ? (_openBlock(), _createElementBlock("option", {
                                        key: 0,
                                        value: route.lan_prefix
                                      }, "/" + _toDisplayString(route.lan_prefix) + "（现有）", 9 /* TEXT, PROPS */, _hoisted_302))
                                    : _createCommentVNode("v-if", true),
                                  _cache[114] || (_cache[114] = _createElementVNode("option", { value: "24" }, "/24", -1 /* CACHED */)),
                                  _cache[115] || (_cache[115] = _createElementVNode("option", { value: "32" }, "/32", -1 /* CACHED */))
                                ], 8 /* PROPS */, _hoisted_301), [
                                  [_vModelSelect, route.lan_prefix]
                                ])
                              ])
                            ]),
                            _createElementVNode("div", _hoisted_303, [
                              _cache[117] || (_cache[117] = _createElementVNode("label", { class: "block text-gray-600 text-xs font-medium mb-1" }, "VNT 客户端虚拟 IP", -1 /* CACHED */)),
                              _withDirectives(_createElementVNode("input", {
                                "onUpdate:modelValue": $event => ((route.vnt_cli_ip) = $event),
                                type: "text",
                                inputmode: "decimal",
                                autocomplete: "off",
                                class: "border rounded w-full py-2 px-3 font-mono text-sm focus:outline-none focus:ring-2 focus:ring-blue-500",
                                placeholder: "如：10.26.0.10"
                              }, null, 8 /* PROPS */, _hoisted_304), [
                                [_vModelText, route.vnt_cli_ip]
                              ])
                            ]),
                            _createElementVNode("button", {
                              type: "button",
                              onClick: $event => (removeWireGuardRoute(index)),
                              class: "shrink-0 px-3 py-2 text-gray-500 hover:text-red-600 text-sm"
                            }, "删除", 8 /* PROPS */, _hoisted_305)
                          ]))
                        }), 128 /* KEYED_FRAGMENT */))
                      ]),
                      _createElementVNode("button", {
                        type: "button",
                        onClick: addWireGuardRoute,
                        class: "mt-3 px-3 py-2 border border-blue-200 text-blue-600 hover:bg-blue-50 rounded text-sm"
                      }, _cache[118] || (_cache[118] = [
                        _createElementVNode("i", { class: "fa-solid fa-plus mr-1" }, null, -1 /* CACHED */),
                        _createTextVNode("添加一条路由 ")
                      ]), 8 /* PROPS */, _hoisted_306),
                      _cache[120] || (_cache[120] = _createElementVNode("p", { class: "text-gray-400 text-xs mt-1" }, "局域网地址默认使用 /24，也可选择 /32；右侧填写负责转发的 VNT 客户端虚拟 IP。", -1 /* CACHED */))
                    ]),
                    (!wireguardEditingPeer)
                      ? (_openBlock(), _createElementBlock("label", _hoisted_307, [
                          _withDirectives(_createElementVNode("input", {
                            "onUpdate:modelValue": $event => ((wireguardPeerForm.enabled) = $event),
                            type: "checkbox",
                            class: "mr-2 h-4 w-4"
                          }, null, 8 /* PROPS */, _hoisted_308), [
                            [_vModelCheckbox, wireguardPeerForm.enabled]
                          ]),
                          _cache[121] || (_cache[121] = _createTextVNode(" 创建后立即启用 "))
                        ]))
                      : _createCommentVNode("v-if", true),
                    _createElementVNode("div", _hoisted_309, [
                      _createElementVNode("button", {
                        type: "button",
                        onClick: closeWireGuardPeerModal,
                        class: "px-4 py-2 text-gray-600 hover:text-gray-800"
                      }, "取消", 8 /* PROPS */, _hoisted_310),
                      _createElementVNode("button", {
                        type: "submit",
                        disabled: loading,
                        class: "bg-blue-600 hover:bg-blue-700 disabled:bg-blue-300 text-white px-4 py-2 rounded font-medium transition"
                      }, _toDisplayString(loading ? '处理中...' : (wireguardEditingPeer ? '保存配置' : (wireguardPeerMode === 'generated' ? '一键生成' : '创建 Peer'))), 9 /* TEXT, PROPS */, _hoisted_311)
                    ])
                  ], 40 /* PROPS, NEED_HYDRATION */, _hoisted_277)),
              modalErrorMsg
                ? (_openBlock(), _createElementBlock("p", _hoisted_312, _toDisplayString(modalErrorMsg), 1 /* TEXT */))
                : _createCommentVNode("v-if", true)
            ])
          ]))
        : _createCommentVNode("v-if", true)
    ], 64 /* STABLE_FRAGMENT */))
  }
}
})(Vue);
createApp(appOptions).mount('#app');
