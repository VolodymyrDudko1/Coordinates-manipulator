const form = document.getElementById("simulationForm");
const canvas = document.getElementById("portalCanvas");
const context = canvas.getContext("2d");
const statusNode = document.getElementById("status");

function drawFrame(points, progress) {
  const width = canvas.width;
  const height = canvas.height;
  context.fillStyle = "#030914";
  context.fillRect(0, 0, width, height);
  const centerX = width / 2;
  const centerY = height / 2;
  const scale = Math.min(width, height) / 8;
  for (let ring = 1; ring <= 4; ring += 1) {
    context.beginPath();
    context.ellipse(centerX, centerY, ring * 34, ring * 12, 0, 0, Math.PI * 2);
    context.strokeStyle = `rgba(49,183,255,${0.35 / ring})`;
    context.stroke();
  }
  if (!points.length) return;
  const visible = points.slice(0, Math.max(2, Math.floor(points.length * progress)));
  const project = (point) => [centerX + point.x * scale - 4 * scale, centerY - point.y * scale / 4];
  context.beginPath();
  visible.forEach((point, index) => {
    const [x, y] = project(point);
    if (index === 0) context.moveTo(x, y); else context.lineTo(x, y);
  });
  context.strokeStyle = "#a9e8ff";
  context.lineWidth = 2;
  context.stroke();
  const [particleX, particleY] = project(visible[visible.length - 1]);
  context.beginPath();
  context.arc(particleX, particleY, 7, 0, Math.PI * 2);
  context.fillStyle = "#fff";
  context.shadowColor = "#31b7ff";
  context.shadowBlur = 18;
  context.fill();
  context.shadowBlur = 0;
}

function animate(points) {
  const started = performance.now();
  const duration = Math.max(1200, points.length * 100);
  function frame(now) {
    drawFrame(points, Math.min(1, (now - started) / duration));
    if (now - started < duration) requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
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
    if (!response.ok) throw new Error(result.error || result.detail || "Simulation failed");
    const points = Array.isArray(result.coordinates) ? result.coordinates : [];
    animate(points);
    statusNode.textContent = `Trajectory complete · ${points.length} geodesic points`;
  } catch (error) {
    statusNode.textContent = error.message;
  }
});
