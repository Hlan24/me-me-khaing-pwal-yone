export default function Home() {
  return (
    <main className="dashboard-shell">
      <script
        dangerouslySetInnerHTML={{
          __html: `(function(){var q=new URLSearchParams(location.search),h=new URLSearchParams(location.hash.replace(/^#/,'')),keys=['auth_action','code','token','token_hash','type','error','error_code','error_description','access_token','refresh_token'],isCallback=keys.some(function(k){return q.has(k)||h.has(k)});if(isCallback){location.replace('/pwal-yon-dashboard.html'+location.search+location.hash)}})();`,
        }}
      />
      <iframe
        className="dashboard-frame"
        src="/pwal-yon-dashboard.html"
        title="ပွဲရုံ စီမံခန့်ခွဲမှုစနစ်"
      />
    </main>
  );
}
