import React from 'react';

const commands = [
  ['-Ss', 'search'],
  ['-Si', 'package info'],
  ['-Sp', 'dependency plan'],
  ['-S', 'install'],
  ['-Rns', 'remove'],
  ['-Qm', 'foreign packages'],
];

const features = [
  {
    number: '01',
    title: 'Search both worlds',
    body: <><code>zay -Ss</code> combines configured repository databases with live AUR results, with clear source labels.</>,
  },
  {
    number: '02',
    title: 'Plan before changing',
    body: <><code>zay -Sp</code> resolves repository and AUR dependencies, then shows the build order without installing anything.</>,
    accent: true,
  },
  {
    number: '03',
    title: 'Keep pacman in charge',
    body: <>Repository installs, removals, and installed-package queries use pacman. zay focuses on AUR discovery and builds.</>,
  },
];

function ExternalLink({ href, children, className = '' }) {
  return <a className={className} href={href} target="_blank" rel="noreferrer">{children}</a>;
}

function Brand({ footer = false }) {
  return (
    <a className={`brand${footer ? ' footer-brand' : ''}`} href="#top" aria-label="zay home">
      <img src="/favicon.svg" width={footer ? 28 : 34} height={footer ? 28 : 34} alt="" />
      <span>zay</span>
    </a>
  );
}

function Terminal() {
  return (
    <div className="terminal-card" aria-label="Example zay commands">
      <div className="terminal-top">
        <div className="window-dots" aria-hidden="true"><i /><i /><i /></div>
        <span>your terminal</span>
        <span className="terminal-mark">zay</span>
      </div>
      <div className="terminal-body">
        <p><span className="prompt">$</span> <span className="command">zay -Ss</span> <span className="argument">firefox</span></p>
        <p className="terminal-comment">Search repos + AUR</p>
        <p><span className="prompt">$</span> <span className="command">zay -Sp</span> <span className="argument">firefox</span></p>
        <p className="terminal-comment">Plan first. Install nothing.</p>
        <p><span className="prompt">$</span> <span className="command">zay -S</span> <span className="argument">package</span></p>
        <p className="terminal-comment">Review AUR files before build.</p>
        <div className="terminal-cursor" aria-hidden="true"><span /></div>
      </div>
      <div className="terminal-foot"><span className="terminal-indicator" /> pacman semantics, AUR aware</div>
    </div>
  );
}

function App() {
  return (
    <>
      <a className="skip-link" href="#main">Skip to content</a>
      <header className="site-header">
        <nav className="nav wrap" aria-label="Main navigation">
          <Brand />
          <div className="nav-links">
            <a href="#features">Features</a>
            <a href="#safety">Safety</a>
            <a href="#install">Install</a>
          </div>
          <ExternalLink className="nav-source" href="https://github.com/nihitdev/zay">View source <span aria-hidden="true">↗</span></ExternalLink>
        </nav>
      </header>

      <main id="main">
        <section className="hero wrap" id="top">
          <div className="hero-copy">
            <p className="eyebrow"><span className="status-dot" /> Made for Arch Linux</p>
            <h1>Pacman, with the AUR <span>built in.</span></h1>
            <p className="hero-text">The commands you know, with AUR search, dependency planning, and reviewed builds in one small native tool.</p>
            <div className="hero-actions">
              <a className="button button-primary" href="#install">Install from AUR <span aria-hidden="true">↓</span></a>
              <ExternalLink className="button button-quiet" href="https://github.com/nihitdev/zay">Explore the code <span aria-hidden="true">↗</span></ExternalLink>
            </div>
            <p className="hero-note">Open source <span>·</span> Zig 0.16 <span>·</span> no helper wrappers</p>
          </div>
          <Terminal />
          <div className="hero-orbit orbit-one" aria-hidden="true" />
          <div className="hero-orbit orbit-two" aria-hidden="true" />
        </section>

        <section className="command-strip" aria-label="Supported command examples">
          <div className="wrap command-list">
            {commands.map(([flag, description]) => <span key={flag}><b>{flag}</b> {description}</span>)}
          </div>
        </section>

        <section className="section wrap" id="features">
          <div className="section-heading">
            <p className="eyebrow">Native by design</p>
            <h2>One familiar workflow.</h2>
            <p>Official packages stay with pacman. AUR support fits around the tools Arch already uses.</p>
          </div>
          <div className="feature-grid">
            {features.map(feature => (
              <article className={`feature-card${feature.accent ? ' feature-card-accent' : ''}`} key={feature.number}>
                <span className="feature-number">{feature.number}</span>
                <h3>{feature.title}</h3>
                <p>{feature.body}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="safety-section" id="safety">
          <div className="wrap safety-layout">
            <div>
              <p className="eyebrow eyebrow-light">AUR means untrusted code</p>
              <h2>Review first.<br />Build as yourself.</h2>
              <p className="safety-copy">AUR build files can run shell code. zay shows first-seen or changed files for review and ties approval to the exact Git revision.</p>
              <ExternalLink className="text-link" href="https://github.com/nihitdev/zay/blob/main/SECURITY.md">Read the security policy <span aria-hidden="true">↗</span></ExternalLink>
            </div>
            <ul className="safety-list">
              <li><span className="check-mark" aria-hidden="true">✓</span><span>Builds run as the invoking user, never root.</span></li>
              <li><span className="check-mark" aria-hidden="true">✓</span><span>New or changed build files need explicit review.</span></li>
              <li><span className="check-mark" aria-hidden="true">✓</span><span><code>--noconfirm</code> never approves untrusted code.</span></li>
              <li><span className="check-mark" aria-hidden="true">✓</span><span>Generated packages are checked before pacman installs them.</span></li>
            </ul>
          </div>
        </section>

        <section className="section install-section wrap" id="install">
          <div className="install-copy">
            <p className="eyebrow">Available on the AUR</p>
            <h2>Build it on Arch.</h2>
            <p>Clone the published <code>zay-git</code> package repository, inspect its build files, and build it as your normal user.</p>
            <ExternalLink className="text-link text-link-dark" href="https://aur.archlinux.org/packages/zay-git">Open zay-git on the AUR <span aria-hidden="true">↗</span></ExternalLink>
          </div>
          <div className="install-code">
            <div className="code-title"><span>Clone, review, build</span><span className="copy-hint">AUR · zay-git</span></div>
            <pre><code><span className="code-comment"># Get the AUR package files</span>{'\n'}<span className="code-prompt">$</span> <span className="code-command">git clone</span> https://aur.archlinux.org/zay-git.git{'\n'}<span className="code-prompt">$</span> <span className="code-command">cd</span> zay-git{'\n\n'}<span className="code-comment"># Inspect the build instructions</span>{'\n'}<span className="code-prompt">$</span> <span className="code-command">less</span> PKGBUILD{'\n\n'}<span className="code-comment"># Build and install as your normal user</span>{'\n'}<span className="code-prompt">$</span> <span className="code-command">makepkg -si</span></code></pre>
          </div>
        </section>

        <section className="upgrade-note wrap">
          <div className="upgrade-icon" aria-hidden="true">↗</div>
          <p><strong>About system upgrades:</strong> <code>-Syu</code> checks for AUR updates and refuses an unsafe partial upgrade. Combined AUR upgrades are still in development.</p>
        </section>
      </main>

      <footer className="site-footer">
        <div className="wrap footer-inner">
          <Brand footer />
          <p>Pacman with native AUR awareness.</p>
          <div className="footer-links">
            <ExternalLink href="https://aur.archlinux.org/packages/zay-git">AUR</ExternalLink>
            <ExternalLink href="https://github.com/nihitdev/zay">GitHub</ExternalLink>
            <ExternalLink href="https://github.com/nihitdev/zay/blob/main/LICENSE">GPL-3.0-or-later</ExternalLink>
          </div>
        </div>
      </footer>
    </>
  );
}

export default App;
