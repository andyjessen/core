/**
  @file mv_registerclient.sas
  @brief Register Client and Secret (admin task)
  @details When building apps on SAS Viya, a client id and secret are usually
  required.  In order to generate them, the Consul Token is required.  To access
  this token, you need to be a system administrator (it is not enough to be in
  the SASAdministrator group in SAS Environment Manager).

  If you are registering a lot of clients / secrets, you may find it more
  convenient to use the [Viya Token Generator]
  (https://sasjs.io/apps/#viya-client-token-generator) (a SASjs Web App to
  automate the generation of clients & secrets with various settings).

  For further information on clients / secrets, see;
  @li https://developer.sas.com/reference/auth/#register
  @li https://proc-x.com/2019/01/authentication-to-sas-viya-a-couple-of-approaches
  @li https://cli.sasjs.io/faq/#how-can-i-obtain-a-viya-client-and-secret

  The default viyaroot location is: `/opt/sas/viya/config`

  Usage:

      %* compile macros;
      filename mc url
        "https://raw.githubusercontent.com/sasjs/core/main/all.sas";
      %inc mc;

      %* generate random client details with openid scope;
      %mv_registerclient(scopes=openid )

      %* generate random client using consul token as input parameter;
      %mv_registerclient(consul_token=12x34sa43v2345n234lasd)

      %* specific client with just openid scope;
      %mv_registerclient(client_id=YourClient
        ,client_secret=YourSecret
        ,scopes=openid
      )

      %* generate random client with 90/180 second access/refresh token expiry;
      %mv_registerclient(scopes=openid
        ,access_token_validity=90
        ,refresh_token_validity=180
      )

  @param [in,out] client_id= The client name.  Auto generated if blank.
  @param [in,out] client_secret= Client secret.  Auto generated if client is
    blank.
  @param [in] consul_token= (0) Provide the actual consul token value here if
    using Viya 4 or above.
  @param [in] scopes= (openid) List of space-seperated unquoted scopes
  @param [in] grant_type= (authorization_code|refresh_token) Valid values are
    "password" or "authorization_code" (unquoted).  Pipe seperated.
  @param [out] outds=(mv_registerclient) The dataset to contain the registered
    client id and secret
  @param [in] access_token_validity= (DEFAULT) The access token duration in
    seconds.  A value of DEFAULT will omit the entry (and use system default)
  @param [in] refresh_token_validity= (DEFAULT)  The duration of validity of the
    refresh token in seconds.  A value of DEFAULT will omit the entry (and use
    system default)
  @param [in] client_name= (DEFAULT) An optional, human readable name for the
    client.
  @param [in] required_user_groups= A list of group names. If a user does not
    belong to all the required groups, the user will not be authenticated and no
    tokens are issued to this client for that user. If this field is not
    specified, authentication and token issuance proceeds normally.
  @param [in] autoapprove= During the auth step the user can choose which scope
    to apply.  Setting this to true will autoapprove all the client scopes.
  @param [in] use_session= If true, access tokens issued to this client will be
    associated with an HTTP session and revoked upon logout or time-out.
  @param [out] outjson= (_null_) A dataset containing the lines of JSON
    submitted. Useful for debugging.

  @version VIYA V.03.04
  @author Allan Bowe, source: https://github.com/sasjs/core

  <h4> SAS Macros </h4>
  @li mf_getplatform.sas
  @li mf_getuniquefileref.sas
  @li mf_getuniquelibref.sas
  @li mf_loc.sas
  @li mf_getquotedstr.sas
  @li mf_getuser.sas
  @li mp_abort.sas

**/

%macro mv_registerclient(client_id=
    ,client_secret=
    ,consul_token=0
    ,client_name=DEFAULT
    ,scopes=openid
    ,grant_type=authorization_code|refresh_token
    ,required_user_groups=
    ,autoapprove=
    ,use_session=
    ,outds=mv_registerclient
    ,access_token_validity=DEFAULT
    ,refresh_token_validity=DEFAULT
    ,outjson=_null_
  );
%local fname1 fname2 fname3 libref access_token url tokloc msg;

%if client_name=DEFAULT %then %let client_name=
  Generated by %mf_getuser() (&sysuserid) on %sysfunc(datetime(),datetime19.
  ) using SASjs;

options noquotelenmax;

%if "&consul_token"="0" %then %do;
  /* first, get consul token needed to get client id / secret */
  %let tokloc=/etc/SASSecurityCertificateFramework/tokens/consul/default;
  %let tokloc=%mf_loc(VIYACONFIG)&tokloc/client.token;

  %if %sysfunc(fileexist(&tokloc))=0 %then %do;
    %let msg=Unable to access the consul token at &tokloc;
    %put &sysmacroname: &msg;
    %put Try passing the value in the consul= macro parameter;
    %put See docs:  https://core.sasjs.io/mv__registerclient_8sas.html;
    %mp_abort(mac=mv_registerclient,msg=%str(&msg))
  %end;

  data _null_;
    infile "&tokloc";
    input token:$64.;
    call symputx('consul_token',token);
  run;

  %if "&consul_token"="0" %then %do;
    %put &sysmacroname: Unable to source the consul token from &tokloc;
    %put It seems your account (&sysuserid) does not have admin rights;
    %put Please speak with your platform adminstrator;
    %put Docs:  https://core.sasjs.io/mv__registerclient_8sas.html;
    %abort;
  %end;
%end;

%local base_uri; /* location of rest apis */
%let base_uri=%mf_getplatform(VIYARESTAPI);

/* request the client details */
%let fname1=%mf_getuniquefileref();
proc http method='POST' out=&fname1
  url="&base_uri/SASLogon/oauth/clients/consul?callback=false%str(&)%trim(
    )serviceId=app";
  headers "X-Consul-Token"="&consul_token";
run;

%put &=SYS_PROCHTTP_STATUS_CODE;
%put &=SYS_PROCHTTP_STATUS_PHRASE;

%let libref=%mf_getuniquelibref();
libname &libref JSON fileref=&fname1;

/* extract the token */
data _null_;
  set &libref..root;
  call symputx('access_token',access_token,'l');
run;

/**
  * register the new client
  */
%let fname2=%mf_getuniquefileref();
%if x&client_id.x=xx %then %do;
  %let client_id=client_%sysfunc(ranuni(0),hex16.);
  %let client_secret=secret_%sysfunc(ranuni(0),hex16.);
%end;

%let scopes=%sysfunc(coalescec(&scopes,openid));
%let scopes=%mf_getquotedstr(&scopes,QUOTE=D,indlm=|);
%let grant_type=%mf_getquotedstr(&grant_type,QUOTE=D,indlm=|);
%let required_user_groups=
  %mf_getquotedstr(&required_user_groups,QUOTE=D,indlm=|);

data _null_;
  file &fname2;
  length clientid clientsecret clientname scope grant_types reqd_groups
    autoapprove $256.;
  clientid='"client_id":'!!quote(trim(symget('client_id')));
  clientsecret=',"client_secret":'!!quote(trim(symget('client_secret')));
  clientname=',"name":'!!quote(trim(symget('client_name')));
  scope=',"scope":['!!symget('scopes')!!']';
  grant_types=symget('grant_type');
  if grant_types = '""' then grant_types ='';
  grant_types=cats(',"authorized_grant_types": [',grant_types,']');
  reqd_groups=symget('required_user_groups');
  if reqd_groups = '""' then reqd_groups ='';
  else reqd_groups=cats(',"required_user_groups":[',reqd_groups,']');
  autoapprove=trim(symget('autoapprove'));
  if not missing(autoapprove) then autoapprove=
    cats(',"autoapprove":',autoapprove);
  use_session=trim(symget('use_session'));
  if not missing(use_session) then use_session=
    cats(',"use_session":',use_session);

  put '{'  clientid  ;
  put clientsecret ;
  put clientname;
  put scope;
  put grant_types;
  if not missing(reqd_groups) then put reqd_groups;
  put autoapprove;
  put use_session;
%if &access_token_validity ne DEFAULT %then %do;
  put ',"access_token_validity":' "&access_token_validity";
%end;
%if &refresh_token_validity ne DEFAULT %then %do;
  put  ',"refresh_token_validity":' "&refresh_token_validity";
%end;

  put ',"redirect_uri": "urn:ietf:wg:oauth:2.0:oob"';
  put '}';
run;

%let fname3=%mf_getuniquefileref();
proc http method='POST' in=&fname2 out=&fname3
    url="&base_uri/SASLogon/oauth/clients";
    headers "Content-Type"="application/json"
            "Authorization"="Bearer &access_token";
run;

/* show response */
%local err;
%let err=NONE;
data _null_;
  infile &fname3;
  input;
  if _infile_=:'{"err'!!'or":' then do;
    length message $32767;
    message=scan(_infile_,-2,'"');
    call symputx('err',message,'l');
  end;
run;
%if "&err" ne "NONE" %then %do;
  %put %str(ERR)OR: &err;
%end;

/* prepare url */
%if %index(%superq(grant_type),authorization_code) %then %do;
  data _null_;
    if symexist('_baseurl') then do;
      url=symget('_baseurl');
      if subpad(url,length(url)-9,9)='SASStudio'
        then url=substr(url,1,length(url)-11);
      else url="&systcpiphostname";
    end;
    else url="&systcpiphostname";
    call symputx('url',url);
  run;
%end;

%put Please provide the following details to the developer:;
%put ;
%put CLIENT_ID=&client_id;
%put CLIENT_SECRET=&client_secret;
%put GRANT_TYPE=&grant_type;
%put;
%if %index(%superq(grant_type),authorization_code) %then %do;
  /* cannot use base_uri here as it includes the protocol which may be incorrect
    externally */
  %put NOTE: Visit the link below and select 'openid' to get the grant code:;
  %put NOTE- ;
  %put NOTE- &url/SASLogon/oauth/authorize?client_id=&client_id%str(&)%trim(
    )response_type=code;
  %put NOTE- ;
%end;

data &outds;
  client_id=symget('client_id');
  client_secret=symget('client_secret');
  error=symget('err');
run;

data &outjson;
  infile &fname2;
  input;
  line=_infile_;
run;

/* clear refs */
filename &fname1 clear;
filename &fname2 clear;
filename &fname3 clear;
libname &libref clear;

%mend mv_registerclient;
