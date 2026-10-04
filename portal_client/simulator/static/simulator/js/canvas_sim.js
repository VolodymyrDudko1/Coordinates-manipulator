const form = document.getElementById("simulationForm");
const canvas = document.getElementById("portalCanvas");
const context = canvas.getContext("2d");
const statusNode = document.getElementById("status");
console.log("[DEBUG] Geodesic Canvas renderer loaded");

function toPoint(point) {
  if (Array.isArray(point) && point.length >= 3) {
    return [Number(point[0]), Number(point[1]), Number(point[2])];
  }
  if (point && typeof point === "object") {
    return [Number(point.x), Number(point.y), Number(point.z)];
  }
  return [NaN, NaN, NaN];
}

function extractPoints(data) {
  const points = Array.isArray(data)
    ? data
    : data?.geodesic_coordinates || data?.coordinates;
  return Array.isArray(points) ? points.map(toPoint) : [];
}

function createProjector(points, width, height) {
  const angle = Math.PI / 6;
  const cosAngle = Math.cos(angle);
  const sinAngle = Math.sin(angle);
  const projected = points.map(([x, y, z]) => ({
    x: x - z * cosAngle,
    y: y - z * sinAngle,
  }));
  const xValues = projected.map((point) => point.x);
  const yValues = projected.map((point) => point.y);
  const minX = Math.min(...xValues);
  const maxX = Math.max(...xValues);
  const minY = Math.min(...yValues);
  const maxY = Math.max(...yValues);
  const margin = 48;
  const rangeX = Math.max(maxX - minX, Number.EPSILON);
  const rangeY = Math.max(maxY - minY, Number.EPSILON);
  const scaleX = (width - margin * 2) / rangeX;
  const scaleY = (height - margin * 2) / rangeY;
  const scale = Math.min(scaleX, scaleY);

  console.log("[DEBUG] Bounding box:", {minX, maxX, minY, maxY});
  console.log("[DEBUG] Scale factors:", {scaleX, scaleY, scale});
  if (!Number.isFinite(scaleX) || !Number.isFinite(scaleY)) {
    console.warn("[DEBUG] Invalid scale factor detected!", {scaleX, scaleY});
  }

  const offsetX = (width - (minX + maxX) * scale) / 2;
  const offsetY = (height + (minY + maxY) * scale) / 2;
  return (point) => ({
    x: offsetX + (point[0] - point[2] * cosAngle) * scale,
    y: offsetY - (point[1] - point[2] * sinAngle) * scale,
  });
}

function drawDiagnosticBorder() {
  context.save();
  context.strokeStyle = "#ff4d6d";
  context.lineWidth = 2;
  context.setLineDash([6, 6]);
  context.strokeRect(2, 2, canvas.width - 4, canvas.height - 4);
  context.restore();
}

function drawFrame(points, progress, project) {
  const width = canvas.width;
  const height = canvas.height;
  context.fillStyle = "#030914";
  context.fillRect(0, 0, width, height);
  const centerX = width / 2;
  const centerY = height / 2;
  for (let ring = 1; ring <= 4; ring += 1) {
    context.beginPath();
    context.ellipse(centerX, centerY, ring * 34, ring * 12, 0, 0, Math.PI * 2);
    context.strokeStyle = `rgba(49,183,255,${0.35 / ring})`;
    context.stroke();
  }
  if (!points.length) return;

  const visible = points.slice(0, Math.max(2, Math.floor(points.length * progress)));
  let outsideViewport = false;
  context.beginPath();
  visible.forEach((point, index) => {
    const {x, y} = project(point);
    outsideViewport ||= x < 0 || x > width || y < 0 || y > height;
    if (index === 0) context.moveTo(x, y); else context.lineTo(x, y);
  });
  context.strokeStyle = "#a9e8ff";
  context.lineWidth = 2;
  context.stroke();
  if (outsideViewport) {
    console.warn("[DEBUG] Projected point is outside viewport");
    drawDiagnosticBorder();
  }

  const {x: particleX, y: particleY} = project(visible[visible.length - 1]);
  context.beginPath();
  context.arc(particleX, particleY, 7, 0, Math.PI * 2);
  context.fillStyle = "#fff";
  context.shadowColor = "#31b7ff";
  context.shadowBlur = 18;
  context.fill();
  context.shadowBlur = 0;
}

function animate(points) {
  if (!points.length) return;
  const project = createProjector(points, canvas.width, canvas.height);
  const started = performance.now();
  const duration = Math.max(1200, points.length * 100);
  function frame(now) {
    drawFrame(points, Math.min(1, (now - started) / duration), project);
    if (now - started < duration) requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

function drawTrajectory(data) {
  console.log("[DEBUG] Raw response received:", data);
  const points = extractPoints(data);
  console.log("[DEBUG] Points count:", points.length);
  if (!points.length) {
    console.warn("[DEBUG] No coordinate points found in response");
    drawDiagnosticBorder();
    return;
  }
  if (points.some((point) => point.some((value) => !Number.isFinite(value)))) {
    console.warn("[DEBUG] Non-finite coordinate detected:", points);
    drawDiagnosticBorder();
    return;
  }
  animate(points);
}

form?.addEventListener("submit", async (event) => {
  event.preventDefault();
  statusNode.textContent = "Calculating trajectory…";
  try {
    const response = await fetch("/simulator/run/", {
      method: "POST",
      body: new FormData(form),
      headers: {"X-Requested-With": "XMLHttpRequest"},
    });
    const result = await response.json();
    if (!response.ok) {
      throw new Error(result.error || result.detail || "Simulation failed");
    }
    drawTrajectory(result);
    const points = extractPoints(result);
    statusNode.textContent = `Trajectory complete · ${points.length} geodesic points`;
  } catch (error) {
    console.error("[DEBUG] Simulation request failed:", error);
    statusNode.textContent = error.message;
  }
});
