import './style.css';
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { FBXLoader } from 'three/addons/loaders/FBXLoader.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { VRMLoaderPlugin } from '@pixiv/three-vrm';

const $ = (selector) => document.querySelector(selector);
const viewport = $('#viewport');
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.NoToneMapping;
viewport.prepend(renderer.domElement);

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(35, 1, 0.01, 100);
camera.position.set(0, 0.95, 3.7);
const controls = new OrbitControls(camera, renderer.domElement);
controls.target.set(0, 0.86, 0);
controls.enableDamping = true;
controls.dampingFactor = 0.08;
controls.minDistance = 0.35;
controls.maxDistance = 12;
controls.update();

scene.add(new THREE.HemisphereLight(0xffffff, 0x59627a, 2.1));
const keyLight = new THREE.DirectionalLight(0xffffff, 2.4);
keyLight.position.set(2.5, 4, 4);
scene.add(keyLight);
const fillLight = new THREE.DirectionalLight(0xb9c8ff, 1.1);
fillLight.position.set(-3, 2, -2);
scene.add(fillLight);

const modelRoot = new THREE.Group();
const content = new THREE.Group();
modelRoot.add(content);
scene.add(modelRoot);

const clock = new THREE.Clock();
const vrms = [];
const animationMixers = [];
let loadedClips = [];
let currentModelName = '';
let currentFormat = '';
let currentView = 'front';
let currentBackground = '#0b1020';
let activeAction = null;
let toastTimer;
let lastCommand = null;
let statusPostPending = false;
let statusDirty = false;

function showToast(message, error = false) {
  const toast = $('#toast');
  toast.textContent = message;
  toast.classList.toggle('error', error);
  toast.classList.add('visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('visible'), 2800);
}

function setLoading(loading) {
  $('#loading').classList.toggle('hidden', !loading);
}

function resize() {
  const width = viewport.clientWidth;
  const height = viewport.clientHeight;
  if (!width || !height) return;
  renderer.setSize(width, height, false);
  camera.aspect = width / height;
  camera.updateProjectionMatrix();
}
new ResizeObserver(resize).observe(viewport);
resize();

function setBackground(color, notify = true) {
  if (!/^#[0-9a-fA-F]{6}$/.test(color)) {
    if (notify) showToast('背景颜色必须使用 #RRGGBB 格式', true);
    return false;
  }
  currentBackground = color.toUpperCase();
  viewport.style.backgroundImage = 'none';
  viewport.style.backgroundColor = currentBackground;
  $('#background-color').value = currentBackground;
  document.querySelectorAll('.swatch').forEach((button) => {
    button.classList.toggle('active', button.dataset.color.toUpperCase() === currentBackground);
  });
  publishStatus();
  return true;
}

function setBackgroundImage(file) {
  if (!file || !/^image\/(png|jpeg|webp)$/.test(file.type)) {
    showToast('请选择 PNG、JPEG 或 WebP 背景图', true);
    return;
  }
  const reader = new FileReader();
  reader.onload = () => {
    viewport.style.backgroundImage = `url("${reader.result}")`;
    currentBackground = `image:${file.name}`;
    document.querySelectorAll('.swatch').forEach((button) => button.classList.remove('active'));
    publishStatus();
    showToast(`已设置背景：${file.name}`);
  };
  reader.onerror = () => showToast('背景图读取失败', true);
  reader.readAsDataURL(file);
}

function fitCamera(direction = new THREE.Vector3(0, 0.04, 1), view = 'fit') {
  const target = new THREE.Vector3(0, 0.86, 0);
  const height = currentModelName ? 1.7 : 1.7;
  const distance = (height / (2 * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)))) * 1.32;
  camera.position.copy(target).add(direction.clone().normalize().multiplyScalar(distance));
  camera.up.set(0, 1, 0);
  if (view === 'top') camera.up.set(0, 0, -1);
  controls.target.copy(target);
  camera.lookAt(target);
  controls.update();
  currentView = view;
  document.querySelectorAll('[data-view]').forEach((button) => {
    button.classList.toggle('active', button.dataset.view === view);
  });
  publishStatus();
}

function setView(view) {
  const views = {
    front: new THREE.Vector3(0, 0.04, 1),
    right: new THREE.Vector3(1, 0.04, 0),
    left: new THREE.Vector3(-1, 0.04, 0),
    back: new THREE.Vector3(0, 0.04, -1),
    top: new THREE.Vector3(0, 1, 0.001),
    perspective: new THREE.Vector3(2.4, 1.1, 3),
    fit: new THREE.Vector3(0, 0.04, 1),
  };
  if (!views[view]) return false;
  fitCamera(views[view], view);
  return true;
}

function disposeObject(object) {
  object.traverse((child) => {
    child.geometry?.dispose();
    const materials = child.material ? (Array.isArray(child.material) ? child.material : [child.material]) : [];
    for (const material of materials) material.dispose();
  });
}

function clearModel() {
  stopAction();
  for (const child of [...content.children]) {
    content.remove(child);
    disposeObject(child);
  }
  vrms.length = 0;
  animationMixers.length = 0;
  loadedClips = [];
  currentModelName = '';
  currentFormat = '';
  modelRoot.rotation.set(0, 0, 0);
  updateExpressionUI();
}

function normalizeContent() {
  content.updateMatrixWorld(true);
  const box = new THREE.Box3().setFromObject(content);
  if (box.isEmpty()) throw new Error('模型中没有可显示的网格');
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());
  const scale = 1.7 / Math.max(size.y, 0.0001);
  content.scale.setScalar(scale);
  content.position.set(-center.x * scale, -box.min.y * scale, -center.z * scale);
  content.updateMatrixWorld(true);
}

function prepareObject(object) {
  object.traverse((child) => {
    if (!child.isMesh) return;
    child.frustumCulled = false;
    const materials = Array.isArray(child.material) ? child.material : [child.material];
    for (const material of materials) {
      if (material.map) material.map.colorSpace = THREE.SRGBColorSpace;
      if (material.userData?.vrm_addon_extension?.mtoon1 && 'metalness' in material) {
        material.metalness = 0;
        material.roughness = 1;
      }
      material.needsUpdate = true;
    }
  });
}

function loadGLTF(arrayBuffer, extension) {
  return new Promise((resolve, reject) => {
    const loader = new GLTFLoader();
    loader.register((parser) => new VRMLoaderPlugin(parser));
    loader.parse(arrayBuffer, '', (gltf) => {
      const vrm = gltf.userData.vrm;
      if (vrm) {
        prepareObject(vrm.scene);
        resolve({ object: vrm.scene, animations: gltf.animations, vrm });
      } else {
        prepareObject(gltf.scene);
        resolve({ object: gltf.scene, animations: gltf.animations });
      }
    }, (error) => reject(new Error(`${extension.toUpperCase()} 解析失败：${error.message || error}`)));
  });
}

async function parseModel(arrayBuffer, extension) {
  if (extension === 'fbx') {
    const object = new FBXLoader().parse(arrayBuffer, '');
    prepareObject(object);
    return { object, animations: object.animations };
  }
  if (extension === 'glb' || extension === 'vrm') return loadGLTF(arrayBuffer, extension);
  throw new Error('仅支持 FBX、GLB 和 VRM 文件');
}

async function installModels(results, name, format) {
  clearModel();
  for (const result of results) {
    if (result.vrm) vrms.push(result.vrm);
    content.add(result.object);
    if (result.animations?.length) {
      loadedClips.push(...result.animations);
      const mixer = new THREE.AnimationMixer(result.object);
      animationMixers.push(mixer);
    }
  }
  normalizeContent();
  currentModelName = name;
  currentFormat = format;
  $('#empty-state').classList.add('hidden');
  $('#model-name').textContent = name;
  $('#model-detail').textContent = `${format.toUpperCase()} · ${vrms.length ? `${vrms[0].expressionManager?.expressions.length || 0} 个 VRM 表情` : '静态模型'}`;
  updateExpressionUI();
  setView('front');
  publishStatus();
}

async function loadFiles(files) {
  const accepted = files.filter((file) => /\.(fbx|glb|vrm)$/i.test(file.name));
  if (!accepted.length) {
    showToast('请选择 FBX、GLB 或 VRM 模型', true);
    return;
  }
  setLoading(true);
  try {
    const results = [];
    for (const file of accepted) {
      const extension = file.name.split('.').pop().toLowerCase();
      results.push(await parseModel(await file.arrayBuffer(), extension));
    }
    const format = accepted.length === 1 ? accepted[0].name.split('.').pop().toLowerCase() : 'fbx';
    await installModels(results, accepted.map((file) => file.name).join(' + '), format);
    showToast(`已载入 ${accepted.length} 个模型文件`);
  } catch (error) {
    console.error(error);
    showToast(error.message || '模型载入失败', true);
  } finally {
    setLoading(false);
  }
}

function updateExpressionUI() {
  const select = $('#expression-select');
  select.replaceChildren();
  const manager = vrms[0]?.expressionManager;
  const expressions = manager?.expressions || [];
  select.disabled = !expressions.length;
  if (!expressions.length) {
    select.add(new Option('当前模型没有 VRM 表情', ''));
  } else {
    select.add(new Option('无表情', ''));
    for (const expression of expressions) select.add(new Option(expression.expressionName, expression.expressionName));
  }
  const hasRig = Boolean(vrms[0]?.humanoid);
  for (const name of ['idle', 'nod', 'wave', 'bow']) {
    $(`[data-action="${name}"]`).disabled = !hasRig;
  }
  $('#rig-hint').textContent = hasRig
    ? `已识别 VRM 骨骼${loadedClips.length ? `和 ${loadedClips.length} 个动画片段` : '，可使用内置动作'}。`
    : '静态模型支持旋转；骨骼动作需要绑定后的 VRM。';
}

function setExpression(name, weight = 1) {
  const manager = vrms[0]?.expressionManager;
  if (!manager) throw new Error('当前模型没有 VRM 表情，请先载入绑定完成的 VRM');
  manager.resetValues();
  if (name && name !== 'neutral') {
    if (!manager.getExpression(name)) throw new Error(`模型中不存在表情：${name}`);
    manager.setValue(name, THREE.MathUtils.clamp(Number(weight) || 0, 0, 1));
  }
  manager.update();
  $('#expression-select').value = name === 'neutral' ? '' : name;
  publishStatus();
  return true;
}

function bone(name) {
  return vrms[0]?.humanoid?.getNormalizedBoneNode(name) || null;
}

function stopAction() {
  if (!activeAction) return;
  for (const [node, quaternion] of activeAction.bones) node.quaternion.copy(quaternion);
  if (activeAction.name === 'spin') modelRoot.rotation.y = activeAction.initialRotation;
  activeAction = null;
  publishStatus();
}

function startAction(name, duration = 2) {
  const supported = ['idle', 'nod', 'wave', 'bow', 'spin'];
  if (!supported.includes(name)) throw new Error(`不支持的动作：${name}`);
  if (name !== 'spin' && !vrms[0]?.humanoid) throw new Error('当前模型尚未绑定，骨骼动作需要 VRM');
  stopAction();
  const names = name === 'wave' ? ['rightUpperArm', 'rightLowerArm', 'rightHand']
    : name === 'nod' ? ['head']
      : ['chest'];
  const bones = new Map();
  for (const boneName of names) {
    const node = bone(boneName);
    if (node) bones.set(node, node.quaternion.clone());
  }
  activeAction = {
    name,
    startedAt: clock.elapsedTime,
    duration: name === 'idle' ? Infinity : THREE.MathUtils.clamp(Number(duration) || 2, 0.2, 30),
    bones,
    initialRotation: modelRoot.rotation.y,
  };
  publishStatus();
  return true;
}

function updateAction() {
  if (!activeAction) return;
  const elapsed = clock.elapsedTime - activeAction.startedAt;
  const progress = activeAction.duration === Infinity ? 0 : Math.min(elapsed / activeAction.duration, 1);
  if (activeAction.name === 'spin') {
    modelRoot.rotation.y = activeAction.initialRotation + progress * Math.PI * 2;
  } else {
    const entries = [...activeAction.bones.entries()];
    for (const [node, rest] of entries) node.quaternion.copy(rest);
    if (activeAction.name === 'wave') {
      const fade = Math.sin(Math.PI * progress);
      const upper = entries.find(([node]) => node === bone('rightUpperArm'));
      const lower = entries.find(([node]) => node === bone('rightLowerArm'));
      upper?.[0].quaternion.multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), -1.05 * fade));
      lower?.[0].quaternion.multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), Math.sin(progress * Math.PI * 6) * 0.5 * fade));
    } else if (activeAction.name === 'nod') {
      const angle = Math.sin(progress * Math.PI * 4) * 0.22 * Math.sin(Math.PI * progress);
      for (const [node] of entries) node.quaternion.multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), angle));
    } else if (activeAction.name === 'bow') {
      const angle = Math.sin(Math.PI * progress) * 0.5;
      for (const [node] of entries) node.quaternion.multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), angle));
    } else if (activeAction.name === 'idle') {
      const angle = Math.sin(elapsed * 1.8) * 0.012;
      for (const [node] of entries) node.quaternion.multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), angle));
    }
  }
  if (progress >= 1) stopAction();
}

async function applyCommand(command) {
  const results = [];
  try {
    if (command.background !== undefined) setBackground(String(command.background));
    if (command.view !== undefined && !setView(String(command.view))) throw new Error(`不支持的视角：${command.view}`);
    if (command.clean !== undefined) document.body.classList.toggle('clean', Boolean(command.clean));
    if (command.expression !== undefined) setExpression(String(command.expression), command.weight ?? 1);
    if (command.action !== undefined) {
      if (command.action === 'stop') stopAction();
      else startAction(String(command.action), command.duration ?? 2);
    }
    lastCommand = { ok: true, command, at: new Date().toISOString() };
    results.push('执行成功');
  } catch (error) {
    lastCommand = { ok: false, error: error.message, command, at: new Date().toISOString() };
    results.push(error.message);
    showToast(error.message, true);
  }
  await publishStatus();
  return results;
}

async function publishStatus() {
  if (statusPostPending) {
    statusDirty = true;
    return;
  }
  statusPostPending = true;
  try {
    do {
      statusDirty = false;
      const status = {
        ready: true,
        model: currentModelName || null,
        format: currentFormat || null,
        vrm: vrms.length > 0,
        expressions: vrms[0]?.expressionManager?.expressions.map((expression) => expression.expressionName) || [],
        animations: loadedClips.map((clip) => clip.name),
        action: activeAction?.name || null,
        background: currentBackground,
        view: currentView,
        clean: document.body.classList.contains('clean'),
        lastCommand,
      };
      try {
        await fetch('/api/status', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(status) });
        $('#api-status').textContent = 'API 已就绪 · 8765';
        $('.connection').classList.add('ready');
      } catch {
        $('#api-status').textContent = '本地渲染模式';
        $('.connection').classList.remove('ready');
      }
    } while (statusDirty);
  } finally {
    statusPostPending = false;
  }
}

async function pollCommands() {
  try {
    const response = await fetch('/api/commands/poll');
    if (!response.ok) return;
    const commands = await response.json();
    for (const item of commands) await applyCommand(item.command);
  } catch {
    // The renderer remains usable when the optional native API is unavailable.
  }
}

$('#open-model').addEventListener('click', () => $('#model-input').click());
$('#empty-open').addEventListener('click', () => $('#model-input').click());
$('#model-input').addEventListener('change', (event) => {
  loadFiles([...event.target.files]);
  event.target.value = '';
});
$('#choose-background').addEventListener('click', () => $('#background-input').click());
$('#background-input').addEventListener('change', (event) => {
  setBackgroundImage(event.target.files[0]);
  event.target.value = '';
});
$('#clear-background').addEventListener('click', () => setBackground($('#background-color').value));
$('#background-color').addEventListener('input', (event) => setBackground(event.target.value, false));
document.querySelectorAll('[data-color]').forEach((button) => button.addEventListener('click', () => setBackground(button.dataset.color)));
document.querySelectorAll('[data-view]').forEach((button) => button.addEventListener('click', () => setView(button.dataset.view)));
document.querySelectorAll('[data-action]').forEach((button) => button.addEventListener('click', () => {
  try {
    if (button.dataset.action === 'stop') stopAction();
    else startAction(button.dataset.action);
  } catch (error) {
    showToast(error.message, true);
  }
}));
$('#expression-select').addEventListener('change', (event) => {
  try { setExpression(event.target.value); } catch (error) { showToast(error.message, true); }
});
$('#reset-expression').addEventListener('click', () => {
  try { setExpression(''); } catch (error) { showToast(error.message, true); }
});

function toggleCleanMode() {
  document.body.classList.toggle('clean');
  resize();
  publishStatus();
}
$('#clean-mode').addEventListener('click', toggleCleanMode);
$('#fullscreen').addEventListener('click', () => {
  if (window.webkit?.messageHandlers?.fullscreen) {
    window.webkit.messageHandlers.fullscreen.postMessage('toggle');
  } else if (document.fullscreenElement) {
    document.exitFullscreen();
  } else {
    document.documentElement.requestFullscreen();
  }
});
window.addEventListener('keydown', (event) => {
  if (event.key.toLowerCase() === 'h' && !['INPUT', 'SELECT', 'TEXTAREA'].includes(document.activeElement.tagName)) toggleCleanMode();
  if (event.key === 'Escape' && document.body.classList.contains('clean')) toggleCleanMode();
});
viewport.addEventListener('dragover', (event) => event.preventDefault());
viewport.addEventListener('drop', (event) => {
  event.preventDefault();
  const files = [...event.dataTransfer.files];
  if (files.length === 1 && /^image\//.test(files[0].type)) setBackgroundImage(files[0]);
  else loadFiles(files);
});

function animate() {
  requestAnimationFrame(animate);
  const delta = Math.min(clock.getDelta(), 0.05);
  updateAction();
  for (const mixer of animationMixers) mixer.update(delta);
  for (const vrm of vrms) vrm.update(delta);
  controls.update();
  renderer.render(scene, camera);
}

setBackground('#0b1020', false);
publishStatus();
setInterval(pollCommands, 300);
animate();
