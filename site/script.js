/* 木照 MuZhao — 页面脚本（原生 JS，无依赖）：
   1. 滚动显现（IntersectionObserver）
   2. 演示区轮播（scroll-snap + 前后按钮 + 圆点） */
(function () {
  "use strict";

  /* ---- 1. 滚动显现 ---- */
  var revealEls = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          e.target.classList.add("in");
          io.unobserve(e.target);
        }
      });
    }, { threshold: 0.12 });
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add("in"); });
  }

  /* ---- 2. 轮播 ---- */
  var track = document.getElementById("carTrack");
  var dotsBox = document.getElementById("carDots");
  if (!track || !dotsBox) return;

  var slides = track.children;
  var dots = [];

  function slideWidth() {
    return slides[0].offsetWidth + 24; /* 与 CSS 中 gap 一致 */
  }
  function currentIndex() {
    return Math.round(track.scrollLeft / slideWidth());
  }
  function goTo(i) {
    i = Math.max(0, Math.min(slides.length - 1, i));
    track.scrollTo({ left: i * slideWidth(), behavior: "smooth" });
  }

  /* 生成圆点 */
  for (var i = 0; i < slides.length; i++) {
    (function (idx) {
      var b = document.createElement("button");
      b.type = "button";
      b.setAttribute("aria-label", "第 " + (idx + 1) + " 张");
      b.addEventListener("click", function () { goTo(idx); });
      dotsBox.appendChild(b);
      dots.push(b);
    })(i);
  }
  function syncDots() {
    var cur = currentIndex();
    dots.forEach(function (d, i) { d.classList.toggle("on", i === cur); });
  }
  track.addEventListener("scroll", function () {
    window.requestAnimationFrame(syncDots);
  }, { passive: true });
  syncDots();

  /* 前后按钮 */
  document.querySelector(".car-btn.prev").addEventListener("click", function () {
    goTo(currentIndex() - 1);
  });
  document.querySelector(".car-btn.next").addEventListener("click", function () {
    goTo(currentIndex() + 1);
  });
})();
