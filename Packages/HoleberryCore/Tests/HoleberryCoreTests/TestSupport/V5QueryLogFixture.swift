/// Source-derived example, not a live capture. Matches the twelve-column v5.21 web response:
/// https://github.com/pi-hole/web/blob/v5.21/api_FTL.php#L329-L337
enum V5QueryLogFixture {
  static let response = """
    {"data":[
      ["1700001800","A","blocked.com","192.168.1.5","1","0","4","0","N/A","-1","N/A","-1"],
      ["1700002700","A","allowed.com","192.168.1.5","2","0","4","100","N/A","-1","1.1.1.1#53","-1"],
      ["1700003300","A","tracker.net","192.168.1.10","1","0","4","0","N/A","-1","N/A","-1"],
      ["1699999999","A","blocked.com","192.168.1.5","1","0","4","0","N/A","-1","N/A","-1"],
      ["1700003601","A","blocked.com","192.168.1.5","1","0","4","0","N/A","-1","N/A","-1"]
    ]}
    """
}
