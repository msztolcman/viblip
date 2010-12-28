" File: blip.vim
" Description: Posting statuses to Blip!
" Maintainer: Marcin Sztolcman <marcin@urzenia.net>
" Version: v0.5
" Date: 2009.05.10
" Info: $Id: viblip.vim -1   $
" History:
" 0.5   - Completely new plugin
"       - network part based on blipapi.py (http://blipapi.googlecode.com)
" 0.4   - Rewrite some parts of code
"       - ability to use json module
"       - new command: RBlip - reconnecting
"       - new method: read - unified GET
"       - dashboard - can get specified quant of statuses, from yourself
"       dashboard or from specified user
"       - message - can read statuses, directed or private messages
" 0.3 better checking for python feature
" 0.2 Methods for read private messages or single status, and some fixes
" 0.1 Initial upload to vim.org
" ------------------------------------------------------------------------------

if !has ('python')
    echohl ErrorMsg
    echo "Error: Required vim compiled with +python"
    echohl None
    finish
endif

if exists ('loaded_viblip')
" FIXME: wlaczyc blokade!!!
"     finish
endif
let loaded_viblip = 1

python << EOF
import vim

import copy
import httplib
import os.path
import random

def gen_boundary ():
    return 'BlipApi.py-'+"".join ([random.choice ('0123456789abcdefghijklmnopqrstuvwxyz') for i in range (18)])

def make_post_data (fields, boundary=None, sep="\r\n"):
    if type (fields) is not dict:   fields = dict (fields)
    if not boundary:                boundary = gen_boundary ()

    output = []
    for k, v in fields.items ():
        output.append ( '--' + boundary )
        output.append ('Content-Disposition: form-data; name="' + k + '"')
        output.append ('')
        output.append (v.encode ('utf-8', 'ignore'))

    output.append ( '--' + boundary + '--' )
    output.append ('')
    return (sep.join (output), boundary)

class BlipApiError (Exception): pass

class BlipApiDashboard (object):
    def read (since_id=None, include=None, limit=10, offset=0):
        url = '/dashboard'
        if since_id:
            url += '/since/' + str (since_id)

        params = list ()
        if limit:   params.append ('limit=' + str (limit))
        if offset:  params.append ('offset=' + str (offset))
        if include: params.append ('include=' + urllib.quote_plus (','.join (include), ','))
        if params:  url += '?' + '&'.join (params)

        return dict (url = url, method = 'get')
    read = staticmethod (read)

class BlipApiDirmsg (object):
    def create (body, user):
        fields = {
            'directed_message[body]':      body,
            'directed_message[recipient]': user,
        }
        data, boundary = make_post_data (fields)
        return dict (
            url         = '/directed_messages',
            method      = 'post',
            data        = data,
            boundary    = boundary,
        )
    create = staticmethod (create)

    def read (id, include=None, ):
        url = '/directed_messages/' + str (id)
        if include:
            url += '?include=' + urllib.quote_plus (','.join (include), ',')
        return dict (url = url, method = 'get')
    read = staticmethod (read)

    def delete (id):
        return dict (url = '/directed_messages/' + str (id), method = 'delete')
    delete = staticmethod (delete)

class BlipApiPrivmsg (object):
    def create (body=None, user=None):
        fields = {
            'private_message[body]':      body,
            'private_message[recipient]': user,
        }
        data, boundary = make_post_data (fields)
        return dict (
            url         = '/private_messages',
            method      = 'post',
            data        = data,
            boundary    = boundary,
        )
    create = staticmethod (create)

    def read (id, include=None):
        url = '/private_messages/' + str (id)
        if include:
            url += '?include=' + urllib.quote_plus (','.join (include), ',')
        return dict (url = url, method = 'get')
    read = staticmethod (read)

    def delete (id):
        return dict (url = '/private_messages/' + str (id), method = 'delete')
    delete = staticmethod (delete)

class BlipApiStatus (object):
    def create (body):
        data, boundary = make_post_data ( { 'status[body]': body, } )
        return dict (
            url         = '/statuses',
            method      = 'post',
            data        = data,
            boundary    = boundary,
        )
    create = staticmethod (create)

    def read (id, include=None):
        url = '/statuses/' + str (id)
        if include:
            url += '?include=' + urllib.quote_plus (','.join (include), ',')
        return dict (url = url, method = 'get')
    read = staticmethod (read)

    def delete (id):
        return dict (url = '/statuses/' + str (id), method = 'delete')
    delete = staticmethod (delete)


class BlipApi (object):
    version = '0.5'
    _modules = dict (
        dashboard   = BlipApiDashboard,
        dirmsg      = BlipApiDirmsg,
        privmsg     = BlipApiPrivmsg,
        status      = BlipApiStatus,
    )

    ## debug
    def __debug_get (self):
        return self._debug
    def __debug_set (self, level):
        if not type (level) is int or level < 0:
            level = 0
        self._debug = level
        self._ch.set_debuglevel (level)
    def __debug_del (self):
        self.debug = 0
    debug = property (__debug_get, __debug_set, __debug_del)

    def __init__ (self, login=None, passwd=None):
        self._login     = login
        self._password  = passwd
        self._debug     = 0
        self._parser    = None
        self._headers   = {
            'Accept':       'application/json',
            'X-Blip-API':   '0.02',
            'User-Agent':   'ViBlip/' + self.version + ' (http://www.vim.org/scripts/script.php?script_id=2492)',
        }

        ## json
        try:
            import json
            self._parser = json.loads
        except ImportError:
            try:
                import cjson
                self._parser = cjson.decode
            except ImportError:
                self._parser = eval

        if self._login and self._password is not None:
            import base64
            self._headers['Authorization'] = 'Basic '+base64.encodestring (self._login + ':' + self._password)

        self._ch = httplib.HTTPConnection ('api.blip.pl', port=httplib.HTTP_PORT)

    def __call__ (self, fn, *args, **kwargs):
        return getattr (self, fn) (*args, **kwargs)

    def __execute (self, method, args, kwargs):
        ## build request data
        req_data = method (*args, **kwargs)

        ## play with request headers
        headers = copy.deepcopy (self._headers)
        headers['Content-Type'] = 'multipart/form-data'
        if 'boundary' in req_data:
            headers['Content-Type'] += '; boundary="' + req_data['boundary'] + '"'
        if 'headers' in req_data:
            headers.update (req_data['headers'])

        req_body = req_data.get ('data', '')
        headers['Content-Length'] = len (req_body)

        self._ch.request (req_data['method'].upper (), req_data['url'], body=req_body, headers=headers)
        response    = self._ch.getresponse ()

        body_parsed = False
        body        = response.read ()
        if response.status in (200, 201, 204):
            ## parser errors need to be handled in higher level (by blipapi.py user)
            body        = self._parser (body)
            body_parsed = True

        return dict (
            # headers     = dict ([(k.lower (), v) for k, v in response.getheaders ()]),
            body        = body,
            body_parsed = body_parsed,
            status_code = response.status,
            status_body = response.reason,
        )

    def __getattr__ (self, fn):
        if '_' not in fn:
            raise AttributeError ('Command not found.')

        module_name, method = fn.split ('_', 1)

        try:
            module = self._modules[module_name]
            method = getattr (module, method)

            if not callable (method):
                raise AttributeError ('Command not found.')
        except Exception, e:
            print e
            raise AttributeError ('Command not found')

        return lambda *args, **kwargs: self.__execute (method, args, kwargs)


# from viblip import BlipApi
# import viblip
# viblip = reload (viblip)
class ViBlip (object):
    def __init__ (self):
        try:
            try:
                fh = open (os.path.join (os.path.expanduser ('~'), '.vibliprc'), 'r')
                login     = fh.readline ().strip ()
                password  = fh.readline ().strip ()
            finally:
                fh.close ()
        except:
            pass

        self.__blip = BlipApi (login, password)

    def dashboard_read (self, limit=3):
        try:
            d = self.__blip.dashboard_read (limit=limit)
            if d['status_code'] in (200, 201, 204):
                print d['body']
            else:
                raise BlipApiError ('[%d] %s' % (d['status_code'], d['status_body']))
        except BlipApiError, e:
            print e

viblip = ViBlip ()
EOF

" function! ViBlipInit ()
"     python viblip = ViBlip ()
" endfunction

function! ViBlipDashboard ()
    python viblip.dashboard_read ()
endfunction

function! ViBlipTest ()
    python << EOF
h = httplib.HTTPConnection ('urzenia.net')
h.request ('get', '/')
q = h.getresponse ()
print type (q), dir (q)
print q.msg.readheaders ()
EOF
endfunction
