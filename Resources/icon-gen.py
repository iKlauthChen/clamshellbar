#!/usr/bin/env python3
"""ClamshellBar 图标：一块亮着的外接屏在后，一台内屏熄灭的笔记本在前。"""
import math

W, C, BODY = 1024, 512, 824
HALF = BODY / 2

TRANSLATE = "translate(512,512) scale(1.02) translate(-512,-480)"


def squircle(r=HALF, n=5.0, steps=720, cx=C, cy=C):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = r * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = r * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((cx + x, cy + y))
    return "M " + " L ".join(f"{x:.2f},{y:.2f}" for x, y in pts) + " Z"


def main():
    body = squircle()
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">
<defs>
  <linearGradient id="bg" x1="0.08" y1="0" x2="0.9" y2="1">
    <stop offset="0" stop-color="#243343"/>
    <stop offset="0.42" stop-color="#121b26"/>
    <stop offset="1" stop-color="#05080d"/>
  </linearGradient>
  <radialGradient id="bloom" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="#5bece0" stop-opacity="0.45"/>
    <stop offset="0.45" stop-color="#2bb6e0" stop-opacity="0.18"/>
    <stop offset="1" stop-color="#2bb6e0" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="scr" x1="0.05" y1="0" x2="0.8" y2="1">
    <stop offset="0" stop-color="#a6fbf0"/>
    <stop offset="0.36" stop-color="#46dfe2"/>
    <stop offset="1" stop-color="#2a7cd0"/>
  </linearGradient>
  <linearGradient id="metal" x1="0" y1="0" x2="0.15" y2="1">
    <stop offset="0" stop-color="#bcc7d4"/>
    <stop offset="0.42" stop-color="#7b8694"/>
    <stop offset="1" stop-color="#3b444f"/>
  </linearGradient>
  <linearGradient id="metalMid" x1="0" y1="0" x2="0.12" y2="1">
    <stop offset="0" stop-color="#95a1b0"/>
    <stop offset="0.5" stop-color="#5f6b78"/>
    <stop offset="1" stop-color="#2e3640"/>
  </linearGradient>
  <linearGradient id="deck" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#94a0ae"/>
    <stop offset="0.5" stop-color="#5d6875"/>
    <stop offset="1" stop-color="#272e37"/>
  </linearGradient>
  <linearGradient id="lidGlass" x1="0.05" y1="0" x2="0.95" y2="1">
    <stop offset="0" stop-color="#0f1721"/>
    <stop offset="0.5" stop-color="#060a10"/>
    <stop offset="1" stop-color="#02050a"/>
  </linearGradient>
  <linearGradient id="sheen" x1="0" y1="0" x2="0.9" y2="1">
    <stop offset="0" stop-color="#aec6df" stop-opacity="0.14"/>
    <stop offset="0.5" stop-color="#aec6df" stop-opacity="0.03"/>
    <stop offset="1" stop-color="#aec6df" stop-opacity="0"/>
  </linearGradient>
  <radialGradient id="vign" cx="0.5" cy="0.44" r="0.72">
    <stop offset="0.55" stop-color="#000000" stop-opacity="0"/>
    <stop offset="1" stop-color="#000000" stop-opacity="0.4"/>
  </radialGradient>
  <filter id="drop" x="-25%" y="-25%" width="150%" height="150%">
    <feDropShadow dx="0" dy="14" stdDeviation="22" flood-color="#000000" flood-opacity="0.55"/>
  </filter>
  <filter id="soft8" x="-40%" y="-40%" width="180%" height="180%">
    <feGaussianBlur stdDeviation="9"/>
  </filter>
  <filter id="soft22" x="-45%" y="-45%" width="190%" height="190%">
    <feGaussianBlur stdDeviation="22"/>
  </filter>
  <clipPath id="bodyClip"><path d="{body}"/></clipPath>
</defs>

<g filter="url(#drop)"><path d="{body}" fill="url(#bg)"/></g>

<g clip-path="url(#bodyClip)">
  <ellipse cx="512" cy="330" rx="360" ry="300" fill="url(#bloom)"/>

  <g transform="{TRANSLATE}">
    <!-- 外接显示器：亮着，在后方 -->
    <g>
      <rect x="162" y="168" width="700" height="378" rx="30" fill="url(#metal)"/>
      <rect x="162" y="168" width="700" height="378" rx="30" fill="none" stroke="#dbe6f2" stroke-opacity="0.42" stroke-width="2.5"/>
      <rect x="178" y="184" width="668" height="346" rx="16" fill="#04070b"/>
      <rect x="184" y="190" width="656" height="334" rx="12" fill="url(#scr)"/>
      <!-- 屏上信号：一块粗白窗口 + 一道短条，小尺寸也认得出「屏亮着」 -->
      <rect x="252" y="232" width="330" height="150" rx="22" fill="#f4ffff" opacity="0.72"/>
      <rect x="252" y="412" width="170" height="38" rx="19" fill="#f4ffff" opacity="0.42"/>
      <rect x="184" y="190" width="656" height="334" rx="12" fill="url(#sheen)"/>
      <!-- 屏幕光晕 -->
      <rect x="184" y="190" width="656" height="334" rx="12" fill="none" stroke="#7ff3e8" stroke-opacity="0.5" stroke-width="10" filter="url(#soft22)"/>
      <!-- 看不见的支架：底边收窄，制造支托感 -->
      <rect x="470" y="540" width="84" height="40" fill="url(#metalMid)" opacity="0.9"/>
      <rect x="176" y="546" width="672" height="10" rx="5" fill="#000000" opacity="0.35" filter="url(#soft8)"/>
    </g>

    <!-- 笔记本：内屏熄灭，在前 -->
    <g>
      <!-- 笔记本落在后屏上的接触阴影 -->
      <g filter="url(#soft22)" opacity="0.32">
        <rect x="322" y="386" width="380" height="300" rx="28" fill="#01060b"/>
      </g>
      <ellipse cx="512" cy="812" rx="250" ry="16" fill="#000000" opacity="0.45"/>
      <!-- 盖子 -->
      <rect x="318" y="398" width="388" height="306" rx="24" fill="url(#metalMid)"/>
      <rect x="318" y="398" width="388" height="306" rx="24" fill="none" stroke="#dbe6f2" stroke-opacity="0.62" stroke-width="3"/>
      <!-- 熄掉的屏 -->
      <rect x="334" y="414" width="356" height="274" rx="12" fill="url(#lidGlass)"/>
      <rect x="334" y="414" width="356" height="274" rx="12" fill="none" stroke="#8fa6bd" stroke-opacity="0.28" stroke-width="2"/>
      <rect x="334" y="414" width="356" height="274" rx="12" fill="url(#sheen)"/>
      <circle cx="512" cy="406" r="5" fill="#9aa6b4" opacity="0.5"/>
      <!-- 后屏的光从上方掠过盖子外沿 -->
      <path d="M320,470 Q318,404 388,400 L636,400 Q702,402 704,470" stroke="#63e8df" stroke-opacity="0.85" stroke-width="9" fill="none" filter="url(#soft8)"/>
      <!-- 铰链 -->
      <rect x="330" y="698" width="364" height="20" rx="8" fill="#161c24"/>
      <rect x="330" y="698" width="364" height="6" rx="3" fill="#c9d6e4" opacity="0.32"/>
      <!-- 键盘面：明显比盖子宽，带厚度与前唇 -->
      <path d="M330,716 L694,716 L740,800 Q744,812 728,812 L296,812 Q280,812 284,800 Z" fill="url(#deck)"/>
      <path d="M330,716 L694,716 L699,727 L325,727 Z" fill="#dbe6f2" opacity="0.26"/>
      <!-- 键盘凹槽（近大远小的梯形）与三排键影 -->
      <path d="M394,736 L630,736 L652,788 Q654,794 646,794 L378,794 Q370,794 372,788 Z" fill="#151b23" opacity="0.62"/>
      <g fill="#dbe6f2" opacity="0.16">
        <rect x="408" y="744" width="208" height="10" rx="5"/>
        <rect x="398" y="762" width="228" height="10" rx="5"/>
        <rect x="388" y="780" width="246" height="8" rx="4"/>
      </g>
      <!-- 前唇厚度 -->
      <path d="M296,806 L728,806 L728,812 Q744,812 740,800 L284,800 Q280,812 296,812 Z" fill="#1d242d" opacity="0.9"/>
      <path d="M302,812 L726,812" stroke="#dbe6f2" stroke-opacity="0.28" stroke-width="3"/>
      <!-- 后屏冷光在键盘面左角的反射 -->
      <path d="M330,720 L404,720" stroke="#63e8df" stroke-opacity="0.4" stroke-width="7" filter="url(#soft8)"/>
    </g>
  </g>

  <rect x="0" y="0" width="{W}" height="{W}" fill="url(#vign)"/>
</g>

<path d="{body}" fill="none" stroke="#ffffff" stroke-opacity="0.10" stroke-width="3"/>
</svg>'''
    with open("clamshellbar.svg", "w") as f:
        f.write(svg)
    print("wrote clamshellbar.svg")


if __name__ == "__main__":
    main()
