const tabs = [...document.querySelectorAll('[role="tab"]')];
function selectTab(tab) {
    for (const item of tabs) {
        const selected = item === tab;
        item.setAttribute("aria-selected", String(selected));
        item.tabIndex = selected ? 0 : -1;
        item.classList.toggle("active", selected);
        document.getElementById(item.getAttribute("aria-controls")).hidden =
            !selected;
    }
}
for (const [index, tab] of tabs.entries()) {
    tab.addEventListener("click", () => selectTab(tab));
    tab.addEventListener("keydown", (event) => {
        let next;
        if (event.key === "ArrowRight" || event.key === "ArrowDown")
            next = (index + 1) % tabs.length;
        if (event.key === "ArrowLeft" || event.key === "ArrowUp")
            next = (index + tabs.length - 1) % tabs.length;
        if (event.key === "Home") next = 0;
        if (event.key === "End") next = tabs.length - 1;
        if (next === undefined) return;
        event.preventDefault();
        selectTab(tabs[next]);
        tabs[next].focus();
    });
}
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
if ("IntersectionObserver" in window && !reducedMotion.matches) {
    const observer = new IntersectionObserver(
        (entries) => {
            for (const entry of entries)
                if (entry.isIntersecting) {
                    entry.target.classList.remove("pending");
                    observer.unobserve(entry.target);
                }
        },
        { threshold: 0.08 },
    );
    document.querySelectorAll(".reveal").forEach((element) => {
        element.classList.add("pending");
        observer.observe(element);
    });
    reducedMotion.addEventListener("change", () => {
        if (reducedMotion.matches) {
            observer.disconnect();
            document
                .querySelectorAll(".pending")
                .forEach((element) => element.classList.remove("pending"));
        }
    });
}
const preview = document.getElementById("app-preview");
preview.addEventListener("pointermove", (event) => {
    if (reducedMotion.matches || event.pointerType !== "mouse") return;
    const rect = preview.getBoundingClientRect();
    preview.style.setProperty(
        "--ry",
        `${((event.clientX - rect.left) / rect.width - 0.5) * 2.2}deg`,
    );
    preview.style.setProperty(
        "--rx",
        `${((event.clientY - rect.top) / rect.height - 0.5) * -2.2}deg`,
    );
});
preview.addEventListener("pointerleave", () => {
    preview.style.setProperty("--rx", "0deg");
    preview.style.setProperty("--ry", "0deg");
});
// The workflow publishes this snapshot from GitHub. Visitors contact only Pages.
async function loadRelease() {
    try {
        const response = await fetch("release.json");
        if (!response.ok) return;
        const release = await response.json();
        const status = document.getElementById("release-status");
        if (release.state === "unreleased") {
            status.textContent = "早期开发阶段，尚无正式 Release。";
        } else if (release.state === "published") {
            status.textContent = `${release.name || release.tag} 已发布。前往 GitHub 查看发布说明与下载。`;
            const link = document.getElementById("release-link");
            // Only project release pages are valid destinations; no third-party assets.
            const url = new URL(release.url);
            if (
                url.origin === "https://github.com" &&
                url.pathname.startsWith("/Kamisato-Yuna/Dayreed/releases/tag/")
            ) {
                link.href = url.href;
                link.querySelector("span").textContent = `获取 ${release.tag}`;
            }
            const meta = document.getElementById("release-meta");
            meta.textContent = `版本 ${release.tag} · ${release.published.slice(0, 10)}`;
            meta.hidden = false;
        }
        if (release.checked)
            document.getElementById("release-checked").textContent =
                `发布信息更新于 ${release.checked.slice(0, 10)} · 实时状态以 GitHub 为准`;
    } catch {
        // Keep a usable release link if the snapshot is unavailable or malformed.
    }
}
loadRelease();
