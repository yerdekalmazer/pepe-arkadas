import Foundation

/// Yalnızca snapshot modu: resmi API yanıt biçiminde örnek JSON'lar, gerçek ayrıştırıcılardan geçirilir.
@MainActor enum IntegrationSamples {
    private static func json(_ s: String) -> Any { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) ?? [:] }
    private static func iso(_ minutesAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutesAgo * 60))
    }
    private static func unix(_ minutesAgo: Double) -> Int { Int(Date().addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970) }

    static func pills() -> [PillProvider] {
        let stripe = StripePill()
        let charges = """
        {"object":"list","data":[
          {"id":"ch_1","amount":4900,"amount_refunded":0,"currency":"eur","status":"succeeded","created":\(unix(1)),"billing_details":{"name":"Sarah Lee","email":"sarah@ornek.com"}},
          {"id":"ch_2","amount":4900,"amount_refunded":0,"currency":"eur","status":"succeeded","created":\(unix(120)),"billing_details":{"name":"Camille Roux","email":null}},
          {"id":"ch_3","amount":118650,"amount_refunded":0,"currency":"eur","status":"succeeded","created":\(unix(300)),"billing_details":{"name":null,"email":null},"receipt_email":"hugo@ornek.com"},
          {"id":"ch_4","amount":1900,"amount_refunded":0,"currency":"eur","status":"failed","created":\(unix(400)),"billing_details":{"name":"Mert Kaya"}}
        ],"has_more":false,"url":"/v1/charges"}
        """
        stripe.freeze(with: StripePill.parse(today: json(charges), recent: json(charges)))

        let github = GitHubPill()
        var gh = GitHubData(login: "yerdekalmazer", mine: GitHubPill.parsePRs(json("""
        {"total_count":3,"incomplete_results":false,"items":[
          {"title":"Notch'ta diff görünümü","number":42,"html_url":"https://github.com/yerdekalmazer/serce/pull/42","repository_url":"https://api.github.com/repos/yerdekalmazer/serce","updated_at":"\(iso(12))","pull_request":{"url":"https://api.github.com/repos/yerdekalmazer/serce/pulls/42"}},
          {"title":"Stripe kartı","number":41,"html_url":"https://github.com/yerdekalmazer/serce/pull/41","repository_url":"https://api.github.com/repos/yerdekalmazer/serce","updated_at":"\(iso(90))","pull_request":{"url":"https://api.github.com/repos/yerdekalmazer/serce/pulls/41"}},
          {"title":"Mozaik ızgarası hızlandı","number":7,"html_url":"https://github.com/yerdekalmazer/tessera/pull/7","repository_url":"https://api.github.com/repos/yerdekalmazer/tessera","updated_at":"\(iso(1500))","pull_request":{"url":"https://api.github.com/repos/yerdekalmazer/tessera/pulls/7"}}
        ]}
        """)), reviewRequested: GitHubPill.parsePRs(json("""
        {"total_count":1,"items":[{"title":"Onboarding metinleri","number":88,"html_url":"https://github.com/divizyon/site/pull/88","repository_url":"https://api.github.com/repos/divizyon/site","updated_at":"\(iso(30))","pull_request":{"url":"x"}}]}
        """)))
        gh.mine[0].ci = GitHubPill.parseChecks(json("""
        {"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]}
        """))
        gh.mine[1].ci = GitHubPill.parseChecks(json("""
        {"total_count":1,"check_runs":[{"status":"completed","conclusion":"success"}]}
        """))
        gh.mine[2].ci = GitHubPill.parseChecks(json("""
        {"total_count":1,"check_runs":[{"status":"in_progress","conclusion":null}]}
        """))
        github.freeze(with: gh)

        let vercel = VercelPill()
        let ms = { (m: Double) in Int(Date().addingTimeInterval(-m * 60).timeIntervalSince1970 * 1000) }
        vercel.freeze(with: VercelPill.parse(json("""
        {"deployments":[
          {"uid":"dpl_1","name":"tessera-landing","url":"tessera-landing-abc.vercel.app","state":"READY","created":\(ms(4)),"target":"production","inspectorUrl":"https://vercel.com/x/tessera-landing/1","meta":{"githubCommitMessage":"Fiyat bölümü güncellendi\\nayrıntı"}},
          {"uid":"dpl_2","name":"kesit","url":"kesit-def.vercel.app","state":"BUILDING","created":\(ms(1)),"target":null,"meta":{"githubCommitMessage":"Klasör yükleme"}},
          {"uid":"dpl_3","name":"hi-link","url":"hi-link-ghi.vercel.app","state":"ERROR","created":\(ms(50)),"target":"production","meta":{"githubCommitMessage":"Kart animasyonu"}},
          {"uid":"dpl_4","name":"tessera-landing","url":"tessera-landing-jkl.vercel.app","state":"READY","created":\(ms(200)),"target":"production","meta":{}}
        ],"pagination":{"count":4,"next":null,"prev":null}}
        """)))

        let n8n = N8nPill()
        n8n.freeze(with: N8nPill.parse(workflows: json("""
        {"data":[{"id":"1","name":"Lead → Trello","active":true},{"id":"2","name":"Haftalık rapor","active":true},{"id":"3","name":"Fatura e-postası","active":true},{"id":"4","name":"Eski senkron","active":false}],"nextCursor":null}
        """), executions: json("""
        {"data":[
          {"id":"1001","finished":true,"mode":"trigger","startedAt":"\(iso(3))","stoppedAt":"\(iso(3))","workflowId":"1","status":"success"},
          {"id":"1000","finished":false,"mode":"trigger","startedAt":"\(iso(40))","stoppedAt":"\(iso(39))","workflowId":"3","status":"error"},
          {"id":"999","finished":true,"mode":"trigger","startedAt":"\(iso(100))","stoppedAt":"\(iso(100))","workflowId":"2","status":"success"},
          {"id":"998","finished":true,"mode":"trigger","startedAt":"\(iso(200))","stoppedAt":"\(iso(199))","workflowId":"1"}
        ],"nextCursor":null}
        """)))

        let resend = ResendPill()
        let rts = { (m: Double) -> String in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
            return f.string(from: Date().addingTimeInterval(-m * 60)) + "+00"
        }
        resend.freeze(with: ResendPill.parse(json("""
        {"object":"list","has_more":false,"data":[
          {"id":"4ef9a417","to":["ayse@ornek.com"],"from":"Tessera <merhaba@tessera.app>","created_at":"\(rts(2))","subject":"Mozaiğin hazır","last_event":"delivered"},
          {"id":"3a9f8c2b","to":["can@ornek.com"],"from":"Tessera <merhaba@tessera.app>","created_at":"\(rts(25))","subject":"Hoş geldin","last_event":"opened"},
          {"id":"2b8e7d1a","to":["eski@ornek.com"],"from":"Tessera <merhaba@tessera.app>","created_at":"\(rts(80))","subject":"Haftalık özet","last_event":"bounced"},
          {"id":"1c7d6e0b","to":["deniz@ornek.com"],"from":"Tessera <merhaba@tessera.app>","created_at":"\(rts(130))","subject":"Şifre sıfırlama","last_event":"clicked"}
        ]}
        """)))

        let notion = NotionPill()
        notion.freeze(with: NotionPill.parse(json("""
        {"object":"list","results":[
          {"object":"page","id":"p1","url":"https://www.notion.so/p1","last_edited_time":"\(iso(6))","icon":{"type":"emoji","emoji":"🧭"},"properties":{"Name":{"id":"title","type":"title","title":[{"type":"text","plain_text":"VizeX yol haritası"}]}}},
          {"object":"page","id":"p2","url":"https://www.notion.so/p2","last_edited_time":"\(iso(70))","icon":null,"properties":{"Başlık":{"id":"title","type":"title","title":[{"plain_text":"Topluluk "},{"plain_text":"notları"}]},"Durum":{"type":"select"}}},
          {"object":"page","id":"p3","url":"https://www.notion.so/p3","last_edited_time":"\(iso(180))","icon":{"type":"emoji","emoji":"📸"},"properties":{"title":{"type":"title","title":[{"plain_text":"Tessera içerik takvimi"}]}}},
          {"object":"page","id":"p4","url":"https://www.notion.so/p4","last_edited_time":"\(iso(3000))","properties":{"title":{"type":"title","title":[]}}}
        ],"has_more":false}
        """)))

        let cal = CalcomPill()
        cal.freeze(with: CalcomPill.parse(json("""
        {"status":"success","data":[
          {"id":1,"uid":"b1","title":"VizeX tanışma","status":"accepted","start":"\(iso(-8))","end":"\(iso(-38))","attendees":[{"name":"Elif Demir","email":"elif@ornek.com"}]},
          {"id":2,"uid":"b2","title":"Tessera geri bildirim","status":"accepted","start":"\(iso(-240))","end":"\(iso(-270))","attendees":[{"name":"Can Öz"}]},
          {"id":3,"uid":"b3","title":"Haftalık senk","status":"accepted","start":"\(iso(-1600))","end":"\(iso(-1630))","attendees":[]}
        ],"pagination":{"hasMore":false}}
        """)))

        return [stripe, github, vercel, n8n, resend, notion, cal]
    }
}
