# -*- coding: utf-8 -*-
import sqlite3
con = sqlite3.connect(r"C:\Users\liuyu\Desktop\WorkPlace\idPhotos\out\tmp\doubao\edge_profile\Default\Network\Cookies")
print("doubao cookies:", con.execute("select count(*) from cookies where host_key like '%doubao%'").fetchone()[0])
print("sessionid:", con.execute("select count(*) from cookies where name='sessionid_ss'").fetchone()[0])
